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

使用方式为定位到文件夹目录下，运行主脚本main.sh来实现。
子脚本位于子目录/bash下
配置文件位于子目录/config下
主菜单
<img width="618" height="625" alt="image" src="https://github.com/user-attachments/assets/4cad8b4c-1a51-4271-9a15-d80aed9f891e" />

基础配置
<img width="397" height="248" alt="image" src="https://github.com/user-attachments/assets/3530855d-8366-437c-b1e8-c53ed5de970d" />

部署容器
<img width="484" height="217" alt="image" src="https://github.com/user-attachments/assets/c03858e6-07fa-4538-8125-7e87305cb208" />
