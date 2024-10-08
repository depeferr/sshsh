#!/bin/bash

sudo su

cd


if [ "$EUID" -ne 0 ]; then
  echo "Bu scripti root olarak çalıştırmalısınız."
  exit
fi


cd


apt update


apt install screen -y


add-apt-repository ppa:deadsnakes/ppa -y


apt install python3.11 python3.11-venv -y


wget https://raw.githubusercontent.com/depeferr/sshsh/refs/heads/main/tif_install_1.0.sh


chmod +x tif_install_1.0.sh

echo "Tüm işlemler başarıyla tamamlandı."
