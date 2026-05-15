# debian_docker_nas
    A shell script suite to configure Debian-based NAS by using Docker (for China)    
    本仓库代码由 DeepSeek AI 生成，作者不主张著作权。
    代码仅供学习交流使用，禁止用于任何商业用途。
    
    本脚本的用途是在一个全新安装的debian上通过导入标准化的json文件快速生成一个基于Docker实现的多功能的NAS/Homeserver
        
    脚本的主要功能：
        1.对非根目录所在磁盘进行挂载或分区
        2.导入标准化的json文件
        3.手动输入json文件并保存
        4.基于json文件对系统进行基础配置
            4.1设置机器的hostname、用户名、密码、
            4.2更新软件源、安装常用软件包、配置SSH
            4.3配置防火墙（使用ufw）
            4.4配置SMB（使用samba）
            4.5配置网络（使用ifupdown，写死为固定IP）
        5.安装docker-ce并基于配置文件预载入镜像源
        6.部署docker容器。
            6.1基于json文件确定的适用类型（轻型、重载）预选从.yml文件中读取的适当容器并快速部署；
            6.2手动部署，部署时自动修正持久化目录，并对特定容器进行专门配置
        7.针对成功部署并运行的容器，使用ufw开放对应端口到局域网（Host模式的容器不支持）
    
    主脚本main.sh位于父目录；
    子脚本位于子目录/bash下；
    配置文件位于子目录/config下
    
    前置准备    
    1.全新安装的debian实例，挂载目录示例如下
                /dev/sda1    /boot/efi                #预留1G 
                /dev/sda2    /boot                    #预留1G
                /dev/sda3    /swap                    #预留2G
                /dev/sda4    /                        #预留约10G
                ####以上为系统盘####
                /dev/sdb1    /mnt/database            #预留约15G，另盘挂载，用于docker的持久化目录，可依据实际需要确定挂载点
                /dev/sdb2    /var/lib/docker          #预留约25G，docker的默认数据存储目录
                /dev/sdb3    /mnt/data/Manage         #预留约60G，作为aira2的下载位置和syncthing的数据位置
                ####以上为配置盘####
                /dev/sdc1    /mnt/data                #数据盘目录，依实际大小确定
                ####以上为数据盘####
    2.（建议）安装好ssh、开放22端口并允许root登录，如果从本机登录并配置，可忽略。
    3.已改为fdisk,不需要了。 ~~（可选）确保apt时有可用的软件源，因为如果要使用脚本进行分区操作，需要安装parted，也可以不管，先进行基础配置再分区就行~~
    4.确保以root身份登录
    
    使用方法
    1.获取并运行脚本
    >wget https://github.com/Bluestone213/debian_docker_nas/releases/download/0.2/debian_docker_nas_v0.2.tar.gz-O && tar debian_docker_nas*.tar.gz
    >cd debian_docker_nas* 
    >bash main.sh
    2.待续

    
    
    主菜单
    
<img width="618" height="625" alt="image" src="https://github.com/user-attachments/assets/4cad8b4c-1a51-4271-9a15-d80aed9f891e" />

    基础配置

<img width="397" height="248" alt="image" src="https://github.com/user-attachments/assets/3530855d-8366-437c-b1e8-c53ed5de970d" />

    部署容器
<img width="484" height="217" alt="image" src="https://github.com/user-attachments/assets/c03858e6-07fa-4538-8125-7e87305cb208" />

