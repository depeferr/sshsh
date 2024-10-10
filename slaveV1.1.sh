#!/bin/bash

TARGET_DIR="tif-miningpool/tig-monorepo/tig-benchmarker"

if [ ! -d "$TARGET_DIR" ]; then
    echo "The directory $TARGET_DIR does not exist."
    exit 1
fi

cd "$TARGET_DIR"

if [ -f "slave.py" ]; then
    rm slave.py
    echo "Old file slave.py removed."
fi

cat > slave.py << EOL
import argparse
import json
import os
import logging
import randomname
import requests
import subprocess
import time
import multiprocessing

logger = logging.getLogger(os.path.splitext(os.path.basename(__file__))[0])

def now():
    return int(time.time() * 1000)

def post_result(batch_id, result, headers, master_ip, master_port):
    try:
        start = now()
        submit_url = f"http://{master_ip}:{master_port}/submit-batch-result/{batch_id}"
        logger.info(f"posting results to {submit_url}")
        resp = requests.post(submit_url, json=result, headers=headers)
        if resp.status_code != 200:
            logger.error(f"status {resp.status_code} when posting results to master: {resp.text}")
        else:
            logger.debug(f"posting results for batch {batch_id} took {now() - start} ms")
    except Exception as e:
        logger.error(f"Error posting results for batch {batch_id}: {e}")

def process_batch(batch, tig_worker_path, download_wasms_folder, num_workers, headers, master_ip, master_port):
    try:
        batch_id = f"{batch['benchmark_id']}_{batch['start_nonce']}"
        logger.debug(f"Processing batch {batch_id}: {batch}")
        
        # Download WASM
        wasm_path = os.path.join(download_wasms_folder, f"{batch['settings']['algorithm_id']}.wasm")
        if not os.path.exists(wasm_path):
            start = now()
            logger.info(f"downloading WASM from {batch['download_url']}")
            resp = requests.get(batch['download_url'])
            if resp.status_code != 200:
                raise Exception(f"status {resp.status_code} when downloading WASM: {resp.text}")
            with open(wasm_path, 'wb') as f:
                f.write(resp.content)
            logger.debug(f"downloading WASM: took {now() - start}ms")
        logger.debug(f"WASM Path: {wasm_path}")
        
        # Run tig-worker
        start = now()
        cmd = [
            tig_worker_path, "compute_batch",
            json.dumps(batch["settings"]), 
            batch["rand_hash"], 
            str(batch["start_nonce"]), 
            str(batch["num_nonces"]),
            str(batch["batch_size"]), 
            wasm_path,
            "--mem", str(batch["wasm_vm_config"]["max_memory"]),
            "--fuel", str(batch["wasm_vm_config"]["max_fuel"]),
            "--workers", str(num_workers),
        ]
        if batch["sampled_nonces"]:
            cmd += ["--sampled", *map(str, batch["sampled_nonces"])]
        logger.info(f"computing batch: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        result = json.loads(result.stdout)
        logger.info(f"computing batch took {now() - start}ms")
        
        # Post the results
        post_result(batch_id, result, headers, master_ip, master_port)
        
    except Exception as e:
        logger.error(f"Error processing batch {batch_id}: {e}")

def main(
    master_ip: str,
    tig_worker_path: str,
    download_wasms_folder: str,
    num_workers: int,
    slave_name: str,
    master_port: int
):
    if not os.path.exists(tig_worker_path):
        raise FileNotFoundError(f"tig-worker not found at path: {tig_worker_path}")
    os.makedirs(download_wasms_folder, exist_ok=True)

    headers = {
        "User-Agent": slave_name
    }
    
    nproc = multiprocessing.cpu_count()
    if nproc >= 256:
        num_batches = 14
    elif nproc >= 128:
        num_batches = 8
    elif nproc >= 48:
        num_batches = 6
    else:
        num_batches = 4  # Default for lower core counts
    
    try:
        while True:
            try:
                # Query for multiple jobs
                start = now()
                get_batch_url = f"http://{master_ip}:{master_port}/get-batch"
                logger.info(f"fetching {num_batches} jobs from {get_batch_url}")
                
                batches = []
                for _ in range(num_batches):
                    resp = requests.get(get_batch_url, headers=headers)
                    if resp.status_code != 200:
                        raise Exception(f"status {resp.status_code} when fetching job: {resp.text}")
                    batches.append(resp.json())
                
                logger.debug(f"fetching {num_batches} jobs: took {now() - start}ms")
                
                with multiprocessing.Pool(processes=num_batches) as pool:
                    pool.starmap(process_batch, [(batch, tig_worker_path, download_wasms_folder, num_workers, headers, master_ip, master_port) for batch in batches])
                
            except Exception as e:
                logger.error(e)
                time.sleep(5)
    except KeyboardInterrupt:
        logger.info("Received interrupt, shutting down...")
    finally:
        logger.info("Shutdown complete")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="TIG Slave Benchmarker")
    parser.add_argument("master_ip", help="IP address of the master")
    parser.add_argument("tig_worker_path", help="Path to tig-worker executable")
    parser.add_argument("--download", type=str, default="wasms", help="Folder to download WASMs to (default: wasms)")
    parser.add_argument("--workers", type=int, default=8, help="Number of workers (default: 8)")
    parser.add_argument("--name", type=str, default=randomname.get_name(), help="Name for the slave (default: randomly generated)")
    parser.add_argument("--port", type=int, default=5115, help="Port for master (default: 5115)")
    parser.add_argument("--verbose", action='store_true', help="Print debug logs")
    
    args = parser.parse_args()
    
    logging.basicConfig(
        format='%(levelname)s - [%(name)s] - %(message)s',
        level=logging.DEBUG if args.verbose else logging.INFO
    )

    main(args.master_ip, args.tig_worker_path, args.download, args.workers, args.name, args.port)
EOL

echo "New file slave.py created successfully."

systemctl restart tif-miningpool.service

journalctl -u tif-miningpool.service -f
