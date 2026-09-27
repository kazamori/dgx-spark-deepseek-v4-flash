# NCCL と nccl-tests のビルドとテストで使う環境変数。
# 使い方: source ~/nccl-env.sh
export CUDA_HOME="/usr/local/cuda"
export MPI_HOME="/usr/lib/aarch64-linux-gnu/openmpi"
export NCCL_HOME="$HOME/nccl/build/"
export LD_LIBRARY_PATH="$NCCL_HOME/lib:$CUDA_HOME/lib64/:$MPI_HOME/lib:$LD_LIBRARY_PATH"

# 管理用 IF（mpirun の制御通信とブートストラップに使う）。
# この環境では Wi-Fi の wlP9s9。有線 LAN（enP7s7）を使う場合は 3 行とも enP7s7 にする。
export UCX_NET_DEVICES=wlP9s9
export NCCL_SOCKET_IFNAME=wlP9s9
export OMPI_MCA_btl_tcp_if_include=wlP9s9
