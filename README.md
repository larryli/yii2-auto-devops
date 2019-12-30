# 使用 GitLab Auto DevOps 在 Kubernetes 上部署 Yii2 应用

首先，感谢 [Guillaume Simon](https://gitlab.com/ipernet) 的 [Deploying Symfony test applications on Kubernetes with GitLab Auto DevOps, k3s and Let's Encrypt - A 30m guide](https://m42.sh/) 一文给予我最大的帮助，使得本文能够完成。

其次，这里只涉及到**部署**。也就是只包含下列内容：

- 自动构建 ([Auto Build](https://docs.gitlab.com/ee/topics/autodevops/#auto-build))
- 自动审查应用 ([Auto Review Apps](https://docs.gitlab.com/ee/topics/autodevops/#auto-review-apps))
- 自动部署 ([Auto Deploy](https://docs.gitlab.com/ee/topics/autodevops/#auto-deploy))
- 自动监控 ([Auto Monitoring](https://docs.gitlab.com/ee/topics/autodevops/#auto-monitoring))

在未来可能会支持：

- 自动测试 ([Auto Test](https://docs.gitlab.com/ee/topics/autodevops/#auto-test))
- 自动代码质量检测 ([Auto Code Quality](https://docs.gitlab.com/ee/topics/autodevops/#auto-code-quality-starter))

也希望有人在这方面为此项目[创建拉取请求](https://github.com/larryli/yii2-auto-devops/compare)。

最后，相信你看得懂上面的文字说明，并为此而来。我们继续~

## 在 Ubuntu 上部署 GitLab + MicroK8s

部署要求：

- GitLab 12.6+
- Kubernetes 1.6+

如果没有现存的部署环境，那么需要：

- 一台至少 8GB 内存、2 核 CPU、100G 硬盘的 vps、实体主机或本地 VirtualBox 虚拟机
- 可选的自有域名与 SSL 证书

两台 4GB 内存的实体主机也是可行，但不建议在同一宿主机配置两台虚拟机（除非宿主机 CPU 核心足够多）。

拥有公网 IP 且 80 与 443 端口可用，可以直接使用 [le-http](https://letsencrypt.org/zh-cn/docs/challenge-types/#http-01-%E9%AA%8C%E8%AF%81%E6%96%B9%E5%BC%8F) 自动配置 SSL。并且不需要配置自有域名，采用 [nip.io](https://nip.io) 的 IP 域名即可。如果仅在内网使用，要使用 https 就需要一个或两个二级域名以及其对应的 SSL 证书。仅使用一个域名时，容器镜像库将使用指定端口与同一域名下的 GitLab 区分。

本示例默认将使用 VirtualBox 虚拟机和仅 http 无 SSL 的 nip.io 域名部署。

### scoop 安装软件包

建议使用 [scoop](https://scoop.sh) 安装 `docker`、`git`、`helm`、`kubectl`、`virtualbox-np`/`virtualbox52-np`（建议 5.2）软件包。

以下脚本示例均使用 Git Bash 作为 Shell。

其中需要 `scoop install helm@2.16.1` 然后 `scoop hold helm` 或者在升级 3.0 版本后使用 `scoop reset helm@2.16.1`。

另外，默认的 helm 安装没有将 tiller 加入到 `~/scoop/shims` 目录中，需要：

```bash
cp ~/scoop/shims/helm.exe ~/scoop/shims/tiller.exe
cp ~/scoop/shims/helm.ps1 ~/scoop/shims/tiller.ps1
cp ~/scoop/shims/helm.shim ~/scoop/shims/tiller.shim
sed -i 's/helm.exe/tiller.exe/g' ~/scoop/shims/tiller.ps1
sed -i 's/helm.exe/tiller.exe/g' ~/scoop/shims/tiller.shim
```

为了方便执行命令，可以设置 helm 与 kubectl 的 Bash 下 Tab 键自动完成：

```bash
mkdir -p ~/.helm && helm completion bash > ~/.helm/completion.bash.inc
mkdir -p ~/.kube && kubectl completion bash > ~/.kube/completion.bash.inc
echo "source '$HOME/.helm/completion.bash.inc'" >> ~/.profile
echo "source '$HOME/.kube/completion.bash.inc'" >> ~/.profile
```

### Docker & docker-machine

另外，虚拟机使用的 Host-Only 网卡默认为 docker-machine 使用的 `192.168.99.0/24` 网段。如果不清楚如何配置，请使用 `docker-machine create` 创建默认的 docker 虚拟机即可。后续有些操作也会用到本地 docker 加速（解决）服务器 CI 构建缓慢（失败）的问题，详细内容请参阅本文末尾的 FAQ 内容。

具体的 docker-machine 创建脚本如下：

```bash
export CI_REGISTRY=registry.192-168-99-8.nip.io
export REGISTRY_MIRROR=https://dockerhub.azk8s.cn
docker-machine create default --engine-registry-mirror=$REGISTRY_MIRROR --engine-insecure-registry=http://$CI_REGISTRY
```

其中 `CI_REGISTRY` 仅在无 SSL 证书情况下指定，`REGISTRY_MIRROR` 为镜像配置，无网络因素时也可以不使用。

如果创建时自动下载 boot2docker.iso 文件缓慢或失败，请使用其他工具或方法下载对应文件到 `~/.docker/machine/cache/` 目录。也希望有组织可以提供 boot2docker.iso 镜像源，并[提交工单](https://github.com/larryli/yii2-auto-devops/issues/new)以修改此处内容。

### VirtualBox 安装 Ubuntu 18.04

虚拟机使用 Ubuntu 18.04 作为基础系统，请从[上交大镜像](https://mirrors.sjtug.sjtu.edu.cn/ubuntu-cd/18.04.3/ubuntu-18.04.3-live-server-amd64.iso)下载安装镜像。

创建虚拟机类型为 `Linux`，版本为 `Ubuntu (64bit)`，内存 `8192 MB`，硬盘 `100.00 GB`。创建完成后先不用启动，设置系统处理器的数量为 `2`；设置网络网卡 2 `启用网络连接`，连接方式为`仅主机 (Host-Only) 网络`，界面名称选择与 docker-machine 创建的 default 虚拟机相同的 Adapter。
（具体查看 default 虚拟机配置）

启动虚拟机，选择启动盘为已下载的 ubuntu-18.04.3-live-server-amd64.iso 文件。

不建议使用中文作为系统语言，默认 `English`。网络配置会显示两块网卡，默认都会 DHCP 配置；其中 `10.0.2.15/24` 是作为外网 NAT 访问用，不需要修改；另一块网卡则是内网使用，不建议使用 DHCP 需要修改为静态 IP，单机部署更需要设置两个静态 IP，当前先只配置一个 IP，选择该网卡 `Edit IPv4`，**IPv4 Method** 选择 `Manual`，**Subnet** 为 `192.168.99.0/24`，**Address** 为 `192.168.99.8`，其他项目留空（不使用该网卡访问外网也就不需要设置网关与域名解析）。**Proxy** 默认为空。**Mirror** 建议修改为 `http://mirrors.aliyun.com/ubuntu`。硬盘分区使用默认的 `Use An Entire Disk`。创建用户并选择 `Install OpenSSH Server`，从 Github.com 拉取公钥。

注意，如果网速没问题，可以在 Snaps 安装页面直接选择安装 microk8s；否则先不选择，安装完系统再说。

系统安装成功重启后，可以选择 ssh 登录系统。虚拟机也可以使用无界面启动节省宿主机资源。

然后，修改虚拟机 IP：

```bash
sudo nano /etc/netplan/50-cloud-init.yaml
```

在：

```yaml
            - 192.168.99.8/24
```

之后增加一行：

```yaml
            - 192.168.99.9/24
```

执行：

```bash
sudo netplan apply
```

如果采用双机部署，请分别安装系统，无需配置多个 IP。

### 安装配置 MicroK8s

没有在系统安装时选择 microk8s 需要先手工安装：

```bash
sudo snap install microk8s --classic
```

其实系统自动安装 microk8s 的进程也是在重启后自动在后台运行安装。前台安装的方便之处在于发现下载速度过慢，可以 Ctrl+C 中止再重试，有一定几率尝试到 1+ Mbs 的下载速度。

相当多的文档会提到安装旧版本的 microk8s，因为新版不再内置 docker 而是使用 containerd。经过试用之后，感觉最新版本要比指定版本的旧版方便许多。当然除了自带的 microk8s.ctr 还不支持 image tag 之外。

使用 `sudo microk8s.status` 可以查看运行状态。如有问题，使用 `sudo microk8s.inspect` 检查。

如果网络存在无法拉取 gcr.io 容器镜像库的情况，需要先调整 containerd：

```bash
sudo nano /var/snap/microk8s/current/args/containerd-template.toml
```

找到 `[plugins]` 下 `[plugins.cri]` 的 `sandbox_image`，修改为：

```ini
    sandbox_image = "gcr.azk8s.cn/google_containers/pause:3.1"
```

然后继续往下 `[plugins.cri.registry]` 下 `[plugins.cri.registry.mirrors]` 删除：

```ini
        [plugins.cri.registry.mirrors."docker.io"]
          endpoint = ["https://registry-1.docker.io"]
```

增加：

```ini
        [plugins.cri.registry.mirrors."docker.io"]
          endpoint = ["https://dockerhub.azk8s.cn"]
        [plugins.cri.registry.mirrors."quay.io"]
          endpoint = ["https://quay.azk8s.cn"]
        [plugins.cri.registry.mirrors."gcr.io"]
          endpoint = ["https://gcr.azk8s.cn/google_containers/"]
        [plugins.cri.registry.mirrors."k8s.gcr.io"]
          endpoint = ["https://gcr.azk8s.cn/google_containers/"]
        [plugins.cri.registry.mirrors."registry.192-168-99-8.nip.io"]
          endpoint = ["http://registry.192-168-99-8.nip.io"]
```

Ctrl+X 保存后退出。其中最后部分仅针对无 SSL 证书的情况。

继续修改 kube-apiserver：

```bash
sudo nano /var/snap/microk8s/current/args/kube-apiserver
```

增加：

```
--runtime-config=apps/v1beta1=true,apps/v1beta2=true,extensions/v1beta1/daemonsets=true,extensions/v1beta1/deployments=true,extensions/v1beta1/replicasets=true,extensions/v1beta1/networkpolicies=true,extensions/v1beta1/podsecuritypolicies=true
--allow-privileged=true
```

支持 chart 脚本与 dind 提权。

重启 microk8s：

```bash
sudo microk8s.stop && sudo microk8s.start
```

无误后，开启 dns 与 storage 组件：

```bash
sudo microk8s.enable dns storage
```

其中 dns 用于内部寻址，storage 用于持久化存储。

使用 `sudo microk8s.kubectl -n kube-system get pods` 查看组件部署状态。

使用 `sudo microk8s.config` 查看 kubectl 配置，复制到本地 `~/.kube/config`。需要替换默认的 `10.0.2.15` IP 换成 `192.168.99.9`。

在宿主机本地测试 `kubectl -n kube-system get pods` 命令。

### 安装配置 GitLab CE

增加软件源并指定域名安装：

```bash
export GITLAB_URL=http://gitlab.192-168-99-8.nip.io
# export GITLAB_MIRROR=https://packages.gitlab.com/gitlab
export GITLAB_MIRROR=https://mirrors.tuna.tsinghua.edu.cn
curl https://packages.gitlab.com/gpg.key 2> /dev/null | sudo apt-key add - &>/dev/null
echo "deb $GITLAB_MIRROR/gitlab-ce/ubuntu/ bionic main" | sudo tee /etc/apt/sources.list.d/gitlab-ce.list
sudo apt-get update
sudo EXTERNAL_URL=$GITLAB_URL apt-get install gitlab-ce
```

参见 [https://about.gitlab.com/install/#ubuntu?version=ce](https://about.gitlab.com/install/#ubuntu?version=ce) 与 [https://mirrors.tuna.tsinghua.edu.cn/help/gitlab-ce/](https://mirrors.tuna.tsinghua.edu.cn/help/gitlab-ce/) 说明。

修改 gitlab 配置：

```bash
sudo nano /etc/gitlab/gitlab.rb
```

找到：

```ruby
# registry_external_url 'https://registry.example.com'
```

修改为：

```ruby
registry_external_url 'http://registry.192-168-99-8.nip.io'
```

如果是单机部署，需要配置 nginx IP；找到：

```ruby
# nginx['listen_addresses'] = ['*', '[::]']
```

修改为：

```ruby
nginx['listen_addresses'] = ['192.168.99.8']
```

另外在：

```ruby
# registry_nginx['listen_port'] = 5050
```

后面增加一行：

```ruby
registry_nginx['listen_addresses'] = ['192.168.99.8']
```

生效 gitlab 配置：

```bash
sudo gitlab-ctl reconfigure
```

可以使用 `sudo gitlab-ctl diff-config` 查看配置修改项。

默认情况下，使用 `EXTERNAL_URL` 为 https 时，GitLab Omnibus 可以使用 [Let’s Encrypt](https://docs.gitlab.com/omnibus/settings/ssl.html#lets-encrypt-integration) 自动配置 SSL 证书。但这需要外网 IP 且 `80` 与 `443` 端口可用（不能修改为其他端口）。

对于内网和虚拟机环境，采用自有域名和手工申请的 SSL 证书可以减少无 https 需要 insecure-registry 的额外设置。

安装完成 gitlab 后，需要先解压复制到 `/etc/gitlab/ssl` 目录：

```bash
sudo mkdir -p /etc/gitlab/ssl
sudo chmod 700 /etc/gitlab/ssl
sudo cp gitlab.example.com.key gitlab.example.com.crt /etc/gitlab/ssl/
sudo cp registry.example.com.key registry.example.com.crt /etc/gitlab/ssl/
```

参见 [https://docs.gitlab.com/omnibus/settings/nginx.html#manually-configuring-https]https://docs.gitlab.com/omnibus/settings/nginx.html#manually-configuring-https)

如果 registry 与 gitlab 使用同一域名则需要，修改：

```ruby
registry_external_url 'https://gitlab.example.com:4567'
registry_nginx['ssl_certificate'] = "/etc/gitlab/ssl/gitlab.example.com.crt"
registry_nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/gitlab.example.com.key"
```

参见 [https://docs.gitlab.com/ee/administration/packages/container_registry.html#configure-container-registry-under-an-existing-gitlab-domain](https://docs.gitlab.com/ee/administration/packages/container_registry.html#configure-container-registry-under-an-existing-gitlab-domain)

### 在 GitLab 上配置 Kubernetes

访问 http://gitlab.192-168-99-8.nip.io 设置 root 密码后登录。

点击 `Configure GitLab` 左侧 `Settings` 下的 `Network`（`/admin/application_settings/network`）。展开（Expand）`Outbound requests`，在白名单（Whitelist）填入 `192.168.99.9`。

继续左侧 `Kubernetes` 中 `Add Kubernetes cluster` 标签栏 `Add existing cluster`。

首先填入 **Kubernetes cluster name** 为 `MicroK8s`，**API URL** 为 `https://192.168.99.9:16443`。

参考 [https://docs.gitlab.com/ee/user/project/clusters/add_remove_clusters.html#existing-gke-cluster](https://docs.gitlab.com/ee/user/project/clusters/add_remove_clusters.html#existing-gke-cluster)

先使用 `kubectl get secrets` 选取一个 `default-token-xxx`，然后执行：

```bash
export SECRET_NAME=default-token-xxx
kubectl get secret $SECRET_NAME -o jsonpath="{['data']['ca\.crt']}" | base64 --decode
```

复制输出的证书内容到 **CA Certificate**。

然后建立一个 `gitlab-admin-service-account.yaml` 文件，内容如下：

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gitlab-admin
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: gitlab-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: gitlab-admin
  namespace: kube-system
```

然后执行：

```bash
kubectl apply -f gitlab-admin-service-account.yaml
```

成功后，使用：

```bash
kubectl -n kube-system describe secret $(kubectl -n kube-system get secret | grep gitlab-admin | awk '{print $1}')
```

获取 `Data` `token` 部分填入 **Service Token**。

添加成功后，先设置 **Base domain** 为 `192-168-99-9.nip.io`。

然后，依次安装 **Helm Tiller**、**Ingress**、**GitLab Runner**，可选安装 **Prometheus**，对于公网 IP 建议安装 **Cert-Manager**。

如果 `kubectl -n gitlab-managed-apps get pods` 发现有 `ImagePullBackOff` 使用 `kubectl -n gitlab-managed-apps describe pod ingress-nginx-ingress-default-backend-xxx-yyy` 查看。

可以在虚拟机上使用类似 `docker image tag` 的操作：

```bash
export GCR_MIRROR=gcr.azk8s.cn/google_containers
export IMAGE_NAME=defaultbackend-amd64
export IMAGE_TAG=1.5
sudo microk8s.ctr image pull $GCR_MIRROR/$IMAGE_NAME:$IMAGE_TAG
sudo microk8s.ctr image export temp.tar $GCR_MIRROR/$IMAGE_NAME:$IMAGE_TAG
sudo microk8s.ctr image import --base-name k8s.gcr.io/$IMAGE_NAME temp.tar
sudo rm temp.tar
```

安装完毕后执行：

```bash
kubectl -n gitlab-managed-apps get svc ingress-nginx-ingress-controller
```

可以看到 `EXTERNAL-IP` 为 `<pending>`。

参考 [https://stackoverflow.com/a/54168660](https://stackoverflow.com/a/54168660)

指定具体 IP：

```bash
export EXTERNAL_IP=192.168.99.9
kubectl -n gitlab-managed-apps patch svc ingress-nginx-ingress-controller -p "{\"spec\": {\"type\": \"LoadBalancer\", \"externalIPs\":[\"$EXTERNAL_IP\"]}}"
```

## 部署 Yii2 应用

### 从 GitHub 导入代码

使用 **Import Project** 选择 **Repo by URL** 填入 `https://github.com/larryli/yii2-auto-devops.git` 创建项目。

### CI / CD 设置

#### staging 与 production 部署方式

**Auto DevOps** 的 **Deployment strategy** 的三项设置：

- *Continuous deployment to production*
- *Continuous deployment to production using timed incremental rollout*
- *Automatic deployment to staging, manual deployment to production*

会与 **Variables** 中的：

- `INCREMENTAL_ROLLOUT_MODE`
- `STAGING_ENABLED`

相互作用。

首先，**Deployment strategy** 的选择会决定 `INCREMENTAL_ROLLOUT_MODE` 和 `STAGING_ENABLED` 默认值，如下表所示：

**Deployment strategy** | `INCREMENTAL_ROLLOUT_MODE` | `STAGING_ENABLED`
--- | --- | ---
*Continuous deployment to production* | - | `false`
*Continuous deployment to production using timed incremental rollout* | `timed` | `false`
*Automatic deployment to staging, manual deployment to production* | `manual` | `true`

参见 [https://docs.gitlab.com/ce/topics/autodevops/#deployment-strategy](https://docs.gitlab.com/ce/topics/autodevops/#deployment-strategy)

所以，部署方式会有下列可能：

**Deployment strategy** | `INCREMENTAL_ROLLOUT_MODE` | `STAGING_ENABLED` | staging | production 
--- | --- | --- | --- | ---
*Continuous deployment to production* | - | - | 无 | 自动部署
*Continuous deployment to production* | - | `true` | 自动部署 | 手动部署
*Continuous deployment to production* | `manual` | - | 无 | 手动增量部署
*Continuous deployment to production* | `manual` | `true` | 自动部署 | 手动增量部署
*Continuous deployment to production using timed incremental rollout* | - | - | 无 | 定时增量部署
*Continuous deployment to production using timed incremental rollout* | - | `true` | 自动部署 | 定时增量部署
*Automatic deployment to staging, manual deployment to production* | - | `false` | 无 | 手动增量部署
*Automatic deployment to staging, manual deployment to production* | - | - | 自动部署 | 手动增量部署

实际六种部署方式，请按照需要预先选择好部署方式。

参见 [https://docs.gitlab.com/ce/topics/autodevops/#incremental-rollout-to-production-premium](https://docs.gitlab.com/ce/topics/autodevops/#incremental-rollout-to-production-premium)

对于增量部署，可选的 `ROLLOUT_STATUS_DISABLED` = `true` 可以在部署日志中不显示状态信息。

#### review 部署

仅一个 `REVIEW_DISABLED` = `false` 关闭默认的自动在分支上审查应用功能。

#### 附加域名

使用单独指定 **Scope** 的 `ADDITIONAL_HOSTS` 或具体 `<env>_ADDITIONAL_HOSTS` 如 `PRODUCTION_ADDITIONAL_HOSTS` 设置部署应用的附加域名。

域名可以为多个，以英文逗号分隔。如：`domain.com, www.domain.com`。

`<env>_ADDITIONAL_HOSTS` 的优先级要比 `ADDITIONAL_HOSTS` 高。

#### MySQL 数据库

可以使用 `MYSQL_ENABLED` = `false` 关闭默认的自动部署 MySQL 服务，从而使用外部 MySQL（可以手工在同一 Kubernets 上安装，也可以使用现有服务）。

当 `MYSQL_ENABLED` = `false` 时，建议按实际情况完整指定 `MYSQL_HOST`、`MYSQL_DB`、`MYSQL_USER` 与 `MYSQL_PASSWORD`。

当 `MYSQL_ENABLED` = `true` 时，一定不要设置 `MYSQL_HOST`，否则无法连接自动安装的 MySQL。`MYSQL_DB`、`MYSQL_USER` 与 `MYSQL_PASSWORD` 可以按需指定。另外可以使用 `MYSQL_VERSION` 指定 MySQL 版本。

#### 数据库初始化与迁移

对于 Yii2 来说，均采用了相同脚本，即：

- `DB_INITIALIZE` = `"/app/wait-for -- /app/yii migrate/up --interactive=0"`
- `DB_MIGRATE` = `"/app/yii migrate/up --interactive=0"`

其中 `DB_INITIALIZE` 使用了特殊的 `wait-for` 脚本等待 Kubernetes 创建 MySQL 服务成功。

使用默认值即可，一般无需修改。

#### 数据库结构缓存

使用 `K8S_SECRET_ENABLE_SCHEMA_CACHE` = `true` 开始缓存，可以配置缓存时间 `K8S_SECRET_SCHEMA_CACHE_DURATION`（单位：秒，默认 `60` 秒）和缓存实体 `K8S_SECRET_SCHEMA_CACHE`（默认 `cache`）。

当 Yii2 缓存也使用数据库缓存时，请不要一开始就是开启此项。一定要部署成功后，后续部署时开启表结构缓存。否则会在建表前出现无法读到缓存（因为缓存表未建）的问题。

#### Cookie 配置

`K8S_SECRET_COOKIE_VALIDATION_KEY` 是唯一一个必须配置的变量，对于 production 也建议使用 **Scope** 单独指定，并勾选 **Masked**。

#### Yii2 环境与调试

默认 `YII_DEBUG=false` `YII_ENV=prod`。

可以使用 `K8S_SECRET_YII_DEBUG` 和 `K8S_SECRET_YII_ENV` 分别配置为 `true` 与 `dev` 开启调试。

并设置 `K8S_SECRET_DEBUG_IP` = `*` 允许所有 IP 可访问调试面板。

注意：默认 Dockerfile 打包 composer 使用了 --no-dev 参数，如果需要线上调试，请修改 Dockerfile 重新打包后启用调试功能。否则会部署失败（无法加载 dev 相关包）。可以在 composer install 后直接 `composer require "yiisoft/yii2-debug" "yiisoft/yii2-gii"`。

#### 其他变量

`K8S_SECRET_ADMIN_EMAIL`、`K8S_SECRET_SENDER_EMAIL`、`K8S_SECRET_SENDER_NAME` 均为演示目的。

注意：当前项目并未配置 postfix 或 smtp，所以无法发送邮件。

### 构建与部署技术架构

整个构建与部署是在 GitLab Auto DevOps 基础上完全自定义。

请先仔细阅读 [https://docs.gitlab.com/ce/topics/autodevops/#customizing](https://docs.gitlab.com/ce/topics/autodevops/#customizing) 的相关说明。

#### 自定义 .gitlab-ci.yml

目前只使用 Build 和 Deploy 两个组件，所以只包含了 `Auto-DevOps.gitlab-ci.yml`、`Jobs/Build.gitlab-ci.yml` 与 `Jobs/Deploy.gitlab-ci.yml` 三块内容。

首先，`variables` 增加了三部分内容：下载镜像源、MySQL 与数据库命令。

其次，`stages` 中删除了 `test` 等阶段。

然后是 Build 部分，针对 `docker:stable-dind` 服务修改了 `entrypoint` 入口。在 Build 的 `variables` 定义了下载镜像源（无网络问题可以去掉）与内部镜像源（非 http 的 CI_REGISTRY 需要，使用 https 可以去掉），以及并发下载数。再指明构建脚本为本地 `./build.sh` 脚本。

最后的 Deploy 部分，除了 `stop_review` 外也一样将部署脚本切换为本地 `./auto-deploy` 脚本。再删除了 `canary` 相关内容（GitLab EE Premium 功能）。`stop_review` 因为设置了 `GIT_STRATEGY: none` 不会检出项目文件，所以必须使用原始部署脚本。

#### 自定义 Dockerfile

采用 Docker multi-stage 多阶段构建。避免在 app 映像中包含 composer 下载缓存与 php 开发包内容。

需要注意的是，composer 执行与 app 的 php 执行并不在同一个映像中。也就是 app 映像中并没有 composer 命令。

#### 自定义 build.sh

去掉了 buildpacks 相关的内容。并针对 multi-stage 构建在每一个构建阶段都 pull & push 阶段映像，以便构建缓存可以正常工作。

#### 自定义 chart

在 `requirements.yaml` 中使用 mysql 替换掉了 postgresql。使用相关 chart 的 0.x 版本是因为兼容 Kubernetes 1.6+ 版本，如有需要可以直接切换最新的 1.x 版本。修改后需更新 `requirements.lock` 文件，详见文末的 FAQ。

在 `values.yaml` 同样使用 mysql 替换掉了 postgresql（没有实现对应 managed 逻辑）。增加了 `nginx.ingress.kubernetes.io/ssl-redirect: "false"`。

增加 Nginx 需要的 `templates/nginx-configMap.yaml` 配置文件。

修改 `templates/db-initialize-job.yaml`、`templates/db-migrate-hook.yaml` 和 `templates/deployment.yaml`，使用 `MYSQL_HOST` 等替换掉 `DATABASE_URL` 环境变量设置。

在 `templates/deployment.yaml` 增加了三个 `volumes` 挂载入口，其中 `assets` 用于 nginx 与 php-fpm 共享 yii 2 生成的 asset 文件，`shared-files` 将 php 入口文件与 css、js 和图像等文件复制到 nginx，`nginx-config-volume` 为 nginx 配置。并在后面的两个容器中分别挂载。同时在 app 主容器最后增加 `postStart` 生命周期，执行复制操作。

在 `containers` 后增加了 nginx 容器，并将 Pod 存活检查移到此容器下。

#### 自定义 auto-devops

在开始部分，将 `DATABASE_URL` 逻辑修改为 `MYSQL_HOST`。

小幅调整了 `download_chart`。

主要修改在 `deploy` 的 `helm upgrade --install`。

### 多项目共用配置

除了 `.gitlab-ci.yml` 文件需要在每个项目复制一份以外。可以类似 GitLab 官方项目创建 `auto-build-image`、`auto-deploy-image` 与 `auto-deploy-app` 三个项目。前两项在 `build` 和 `.auto-deploy` 下直接修改对应的 `image` 即可。最后一项可以在 `variables` 中定义 `AUTO_DEVOPS_CHART` 相关变量（需要自建 chart 仓库）。

### 未完事项

### SSL 证书

当前默认启用了 TLS（即 https 访问），启用 Cert-Manager 管理证书（自动从 Let's Encrypt 申请）。**禁用**了 `nginx.ingress.kubernetes.io/ssl-redirect`（即访问 http 自动跳转 https）。

后续需要：

- 可配置的 `ssl-redirect`
- 给 `ADDITIONAL_HOSTS` 配置指定的 SSL 证书（另外申请，如泛域名证书）

#### 缓存 Cache

当前直接使用的文件缓存，也就是缓存只存在与 pod 内部。在 scale 后无法在多个 pod 之间共享缓存，也就是无法利用缓存在不同请求之间交换数据。

注意：仅仅作为临时缓存（如页面缓存），除了性能问题是不存在其他问题的。

后续：

- 配置 Memcached 服务，并配置 Yii2 缓存组件

可选配置 Redis 缓存，谨慎使用 MySQL 数据库缓存。不建议使用 php apc/zend 等 PHP 扩展缓存（和文件缓存一样仅支持单机）。

#### 会话 Session

当前直接用 PHP 系统会话，与缓存一样只支持单机。

后续：

- 配置 Redis 服务，并配置 Yii2 会话组件

可选配置 MySQL 数据库会话。使用缓存会话组件时一定要注意缓存组件本身是不是支持 scale。

#### MongoDb

后续：

- 配置 MongoDb 服务

可选替换数据库、缓存、会话等组件。

#### 上传文件 Upload

PHP 上传文件到 Nginx 下载。

后续：

- 配置持久化卷同时挂载到 Nginx 和 App

#### 定时任务

增加定时任务。

后续：

- 配置定时任务

#### 后台队列处理

增加后台服务。

后续：

- 配置 beanstalkd 服务，并配置 yii2-queue 队列组件与后台队列服务

可选配置 redis 队列。不建议使用数据库队列（性能问题）。

#### Assets 构建

Yii2 支持 `yii asset/compress` 打包 css/js 资源。

后续：

- 在构建时预先打包资源

#### SMTP 邮件发送

邮件发送功能。

后续：

- 配置 SMTP 参数

#### 附加 Nginx 模块

定制化 Nginx 映像，增加 Nchan 组件。

后续：

- 构建额外的 Nginx 映像（使用其他项目或分支）
- 配置 Nginx 映像

## FAQ

### 使用本地 Docker 缓存加速（解决） CI 构建缓慢（失败）

如果服务器 CI 构建出现问题，可以选择在本地使用 Docker 构建后推到容器镜像库。当然，不同分支切换时因为缓存不存在，也可以拉取其他分支的镜像缓存回来，通过 tag 改名再推到容器镜像库作为缓存加速服务器 CI 执行。

Tag 改名：

```bash
export CI_REGISTRY=registry.192-168-99-8.nip.io
export PROJECT=root/yii2-auto-devops
export SOURCE_BRANCH=master
export BRANCH=foobar
docker login $CI_REGISTRY
docker pull $CI_REGISTRY/$PROJECT/$SOURCE_BRANCH:composer
docker tag $CI_REGISTRY/$PROJECT/$SOURCE_BRANCH:composer $CI_REGISTRY/root/yii2-auto-devops/$BRANCH:composer
docker push $CI_REGISTRY/$PROJECT/$BRANCH:composer
docker pull $CI_REGISTRY/$PROJECT/$SOURCE_BRANCH:builder
docker tag $CI_REGISTRY/$PROJECT/$SOURCE_BRANCH:builder $CI_REGISTRY/root/yii2-auto-devops/$BRANCH:builder
docker push $CI_REGISTRY/$PROJECT/$BRANCH:builder
```

本地构建：

```bash
export CI_REGISTRY=registry.192-168-99-8.nip.io
export PROJECT=root/yii2-auto-devops
export BRANCH=foobar
docker login $CI_REGISTRY
docker build --target composer --tag $CI_REGISTRY/$PROJECT/$BRANCH:composer .
docker push $CI_REGISTRY/$PROJECT/$BRANCH:composer
docker build --target composer --tag $CI_REGISTRY/$PROJECT/$BRANCH:builder .
docker push $CI_REGISTRY/$PROJECT/$BRANCH:builder
docker build --tag $CI_REGISTRY/$PROJECT/$BRANCH:latest .
docker push $CI_REGISTRY/$PROJECT/$BRANCH:latest
```

注意：本地构建会因为 Windows 与 Linux 文件系统不同造成差异，从而使得缓存失效。

### 更新 chart requirements.lock

```bash
export CHART_MIRROR=https://mirror.azure.cn/kubernetes/charts/
helm init --client-only --stable-repo-url $CHART_MIRROR
helm dependency update chart/
```

### 部署出错提示 Error: error installing: namespaces "staging" not found

不小心直接 `kubectl delete namespace` 会出现此问题。

请使用 GitLab 12.6.0 以上版本，在 **Kubernetes** 的 **Advanced settings** 中点击 **Clear cluster cache**。

参见 [https://docs.gitlab.com/ee/user/project/clusters/index.html#clearing-the-cluster-cache](https://docs.gitlab.com/ee/user/project/clusters/index.html#clearing-the-cluster-cache)

### 部署出错提示 Error: UPGRADE FAILED: "staging" has no deployed releases

一般会出现在上一次部署失败或被取消后。

在本地使用 helm 清除（请先配置 kubectl config）：

```bash
export CHART_MIRROR=https://mirror.azure.cn/kubernetes/charts/
export KUBE_NAMESPACE=yii2-auto-devops-1-staging
export CHART_NAME=staging
export TILLER_NAMESPACE=$KUBE_NAMESPACE
tiller -listen localhost:44134 &
export HELM_HOST="localhost:44134"
helm init --client-only --stable-repo-url $CHART_MIRROR
helm ls
helm delete $CHART_NAME --purge --tiller-namespace $KUBE_NAMESPACE
```

参见 [https://gitlab.com/gitlab-org/gitlab-foss/issues/54760](https://gitlab.com/gitlab-org/gitlab-foss/issues/54760)

## 感谢

对上文中提到的所有 mirrors 维护者表示衷心的感谢！
