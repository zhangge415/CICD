#!/bin/bash
# Author: Alex Zhang
# Create Time: 2023/10/11 
# Update Time:
# Version: 1.0
master_hostname=k8s-master
node01_hostname=k8s-node01
master_ip=172.16.30.75
node01_ip=172.16.20.155
docker_version="20.10.9-3.el7"
containerd_version="containerd.io-1.6.6"
kubectl_version="kubectl-1.25.0-0.x86_64"
kubeadm_version="kubeadm-1.25.0-0.x86_64"
kubelet_version="kubelet-1.25.0-0.x86_64"
ssh_public_key=/root/ali.pem
# 设置 Kubernetes 版本号
kubernetes_version="v1.25.0"
# 设置 pod 网络和服务网络 CIDR
pod_network_cidr="10.244.0.0/16"
service_cidr="10.96.0.0/12"
# 设置容器镜像仓库
image_repository="registry.cn-hangzhou.aliyuncs.com/google_containers"


#禁用非root用户运行
if [[ $EUID -ne 0 ]]; then
   echo "请以 root 用户身份运行此脚本"
   exit 1
fi

host_init() {
# 设置主机名
hostnamectl set-hostname $master_hostname

#配置hosts
cat << EOF >> /etc/hosts
$master_ip $master_hostname
$node01_ip $node01_hostname
EOF

# 配置yum、安装依赖包
yum install -y device-mapper-persistent-data lvm2 wgetnet-tools nfs-utils lrzsz gcc gcc-c++ make cmake libxml2-devel openssl-devel curl curl-devel unzip sudo ntp libaio-devel wget vim ncurses-devel autoconf automake zlib-devel python-devel epel-release openssh-server socat ipvsadm conntrack telnet &> /dev/null;
if [ $? -ne 0 ];then
    echo -e "\033[36m依赖包安装失败\033[0m"
    exit 1
else
    echo -e "\033[36mdevice-mapper-persistent-data lvm2 wgetnet-tools nfs-utils lrzsz gcc gcc-c++ make cmake libxml2-devel openssl-devel curl curl-devel unzip sudo ntp libaio-devel wget vim ncurses-devel autoconf automake zlib-devel python-devel epel-release openssh-server socat ipvsadm conntrack telnet 已安装\033[0m"
fi

# 时间同步
if command -v ntpdate &> /dev/null; then
    ntpdate cn.pool.ntp.org
    if [ $? -ne 0 ];then
        echo -e "\033[36m时间失败\033[0m"
        exit 1
    else
        echo -e "\033[36m时间已同步\033[0m"
    fi
else
    echo -e "\033[36m未找到 ntpdate 命令，无法进行时间同步，重新安装，请稍等。。。\033[0m"
    yum -y install ntpdate  &> /dev/null
    echo -e "\033[36mntpdate 已安装 \033[0m"
    ntpdate cn.pool.ntp.org
fi

# 关闭 Swap 空间
if [[ $(swapon --show) ]]; then
    swapoff -a
    sed -i '/swap/d' /etc/fstab
fi

# 关闭 SELinux
if command -v setenforce &> /dev/null; then
    setenforce 0
    sed -i 's/^SELINUX=enforcing$/SELINUX=disabled/' /etc/selinux/config
fi

# 关闭防火墙
if command -v systemctl &> /dev/null; then
    if systemctl is-active --quiet firewalld; then
        systemctl stop firewalld
        systemctl disable firewalld
    fi
fi

# 修改系统内核参数
if ! lsmod | grep br_netfilter &> /dev/null; then
    modprobe br_netfilter
    echo 'br_netfilter' > /etc/modules-load.d/br_netfilter.conf
fi

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sysctl -p /etc/sysctl.d/k8s.conf

配置路由转发
echo 1 > /proc/sys/net/ipv4/ip_forward 

# 配置kubernetes yum源
yum install yum-utils -y
yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
if [[ ! -f /etc/yum.repos.d/kubernetes.repo ]]; then
   cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=0
EOF
else 
  sleep 60
  echo -e "\033[36mkubernetes源已经存在，无需创建\033[0m"
fi
}

#部署docker
install_docker() {
    # 配置 Docker 加速
    DOCKER_DAEMON_JSON_FILE="/etc/docker/daemon.json"
    if command -v docker &> /dev/null; then
        if [[ ! -f $DOCKER_DAEMON_JSON_FILE ]]; then
            mkdir -p /etc/docker
            cat <<EOF > $DOCKER_DAEMON_JSON_FILE
{
"registry-mirrors":["https://vh3bm52y.mirror.aliyuncs.com","https://registry.docker.cn.com","https://docker.mirrors.ustc.edu.cn","https://dockerhub.azk8s.cn","http://hub.mirror.c.163.com"]
}
EOF

            systemctl restart docker 
            systemctl enable docker
        fi
    else 
        #配置国内安装docker yum源
        yum install -y yum-utils device-mapper-persistent-data lvm2 &> /dev/null;
        yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo &> /dev/null;
        sed -i 's+download.docker.com+mirrors.aliyun.com/docker-ce+' /etc/yum.repos.d/docker-ce.repo &> /dev/null;
        yum clean all && yum makecache &> /dev/null
        sudo yum -y install docker-ce-$docker_version docker-ce-cli-$docker_version &> /dev/null
        mkdir -p /etc/docker
        cat <<EOF > $DOCKER_DAEMON_JSON_FILE
{
"registry-mirrors":["https://vh3bm52y.mirror.aliyuncs.com","https://registry.docker.cn.com","https://docker.mirrors.ustc.edu.cn","https://dockerhub.azk8s.cn","http://hub.mirror.c.163.com"]
}
EOF
        systemctl enable docker --now 
        echo -e "docker 当前状态为：\033[34m$(systemctl status  docker |awk '/Active:/{print $3}'|sed 's/[()]//g')\033[0m"
        echo -e "docker 部署版本：\033[34m$docker_version\033[0m"
    fi
}

#检查是否已经安装了指定版本的 Containerd
is_containerd_installed() {
    rpm -qa | grep "$containerd_version" &> /dev/null
    return $?
}

# 安装 Containerd
install_containerd() {
    if is_containerd_installed; then
        echo -e "\033[36m$containerd_version 已安装\033[0m"
        exit 1
    else
        echo -e "\033[36m$containerd_version 不存在，正在安装...\033[0m"
        yum install -y containerd.io-1.6.6 &> /dev/null
        if [ $? -eq 0 ]; then
            echo -e "\033[34m$containerd_version 安装成功\033[0m"
            configure_containerd
            configure_crictl
        else
            echo -e "\033[34m$containerd_version 安装失败\033[0m"
            exit 1
        fi
    fi
}

# 配置 Containerd
configure_containerd() {
        echo -e "\033[36m配置 Containerd...\033[0m"
        mkdir -p /etc/containerd
        containerd config default > /etc/containerd/config.toml
        sed -i 's# SystemdCgroup = .*# SystemdCgroup = true#' /etc/containerd/config.toml
        sed -i 's# sandbox_image = .*# sandbox_image = "registry.aliyuncs.com/google_containers/pause:3.6"#' /etc/containerd/config.toml
        systemctl enable containerd --now

        if systemctl is-active containerd &> /dev/null; then
            echo -e "\033[34mContainerd 已经运行\033[0m"
        else
            echo -e "\033[34mContainerd 运行失败，请查看\033[0m"
            exit 1
        fi
}

# 配置 crictl
configure_crictl() {
        echo -e "\033[36m配置 crictl...\033[0m"
        cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
        systemctl restart containerd
        sed -i 's/config_path = ""/config_path = "\/etc\/containerd\/certs.d"/' /etc/containerd/config.toml

        if [ ! -d /etc/containerd/certs.d/docker.io/ ]; then
            mkdir -p /etc/containerd/certs.d/docker.io/
            echo -e "[host.\"https://vh3bm52y.mirror.aliyuncs.com\",host.\"https://registry.docker-cn.com\"]\ncapabilities = ["pull"]" > /etc/containerd/certs.d/docker.io/hosts.toml
            # 重启 containerd
            systemctl restart containerd
        fi
}

#查看contained状态
iscontainerd_status() {
    containerd_status=`systemctl status containerd |awk '/Active:/{print $3}'|sed 's/[()]//g'`
    echo -e "\033[36mcontainerd当前运行状态：$containerd_status\033[0m"
}


containerd_main() {
    if [ -f /etc/yum.repos.d/docker-ce.repo ]; then
        install_containerd
        configure_containerd
        configure_crictl
    else
        yum install -y yum-utils device-mapper-persistent-data lvm2 &> /dev/null
        yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo &> /dev/null
        sed -i 's+download.docker.com+mirrors.aliyun.com/docker-ce+' /etc/yum.repos.d/docker-ce.repo &> /dev/null
        yum clean all && yum makecache &> /dev/null
        install_containerd
        configure_containerd
        configure_crictl
        iscontainerd_status
    fi
}

#master节点集群初始化
k8s_init() {
kubeadm init --kubernetes-version=$kubernetes_version \
    --pod-network-cidr=$pod_network_cidr \
    --service-cidr=$service_cidr \
    --ignore-preflight-errors=Swap \
    --image-repository "$image_repository" \
    --apiserver-advertise-address=$master_ip \
    --node-name=$master_hostname
}

#master安装k8s
install_master_k8s() {
     yum -y install $kubectl_version $kubeadm_version $kubelet_version
     if [ $? -ne 0 ];then
        echo -e "\033[34mkubelet 部署失败，请检查！\033[0m"
        exit 1
     else 
        # 配置容器运行时
        crictl config runtime-endpoint /run/containerd/containerd.sock
        systemctl enable kubelet --now 
        k8s_init
        kubelet_status=$(systemctl status kubelet | awk '/Active/{print $3}'  | sed 's/[()]//g') 
        echo -e "\033[34m当前kubelet的状态为：\033[0m"
        mkdir -p $HOME/.kube
  			sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  			sudo chown $(id -u):$(id -g) $HOME/.kube/config

     fi
} 

k8s_tab() {
    yum install -y bash-completion
    source /usr/share/bash-completion/bash_completion
    source <(kubectl completion bash)
    echo "source <(kubectl completion bash)" >> ~/.bashrc
    echo -e "\033[34mk8s集群已配置完成，可以使用\033[0m"
}

k8s_status() {
    echo -e "\033[34m查看pods运行状态\033[0m"
    kubectl get pods --all-namespaces
    sleep 3
    echo -e "\033[34m查看节点运行状态\033[0m"
    kubectl get nodes 
    sleep 3
    echo -e "\033[34m查看集群运行状态\033[0m"
    kubectl get cs 
    sleep 3
    echo -e "\033[34m查看集群apiserver运行状态\033[0m"
    kubectl cluster-info 
    sleep 3

}




install_node_k8s() {
     echo -e "\033[36mnode实例环境初始化:\033[0m"
     host_init
     echo -e "\033[36mnode安装containerd:\033[0m"
     containerd_main
     yum -y install $kubectl_version $kubeadm_version $kubelet_version
     if [ $? -ne 0 ];then
        echo -e "\033[34mkubelet 部署失败，请检查！\033[0m"
        exit 1
     else 
        # 配置容器运行时
        crictl config runtime-endpoint /run/containerd/containerd.sock
        systemctl enable kubelet --now 
        k8s_node=$(ssh -i ali.pem  root@$master_ip "kubeadm token create --print-join-command")
        $k8s_node
     fi
}




main() {
    echo -e "\033[36m选择要安装的组件:\033[0m"
    echo -e "\033[33m1. 安装 Docker\033[0m"
    echo -e "\033[33m2. 安装 Containerd\033[0m"
    echo -e "\033[33m3. k8s环境初始化\033[0m"
    echo -e "\033[33m4. master节点安装kubelet、kubectl、kubeadm\033[0m"
    echo -e "\033[33m5. node节点安装kubelet、kubectl、kubeadm\033[0m"
    echo -e "\033[33m6. 配置集群tab键\033[0m"
    echo -e "\033[33m7. 查看集群状态\033[0m"
    echo -e "\033[33m8. 退出脚本\033[0m"
    read -p "请输入选项数字: " choice

    case $choice in
        1)
            configure_docker_acceleration
            main
            ;;
        2)
            containerd_main
            main
            ;;
        3) 
            host_init
            main
            ;;
        4)  
            install_master_k8s
            main
            ;;
        5)
            install_node_k8s
            main
            ;;
        6)
            k8s_tab
            main
            ;;
        7)
            k8s_status
            main
            ;;
        8)
            exit 1
            ;; 
        *)
            echo "无效的选项,自动退出"
            exit 1
            ;;
    esac
}
main
