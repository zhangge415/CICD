Gitlab 官方提供了 Helm 的方式在 Kubernetes 集群中来快速安装，但是官方提供的 Helm Chart 包（https://charts.gitlab.io/）非常复杂，也需要一个域名来绑定 GitLab 实例，所以我们这里使用自定义的方式来安装，也就是自己来定义一些资源清单文件。

Gitlab 主要涉及到 3 个应用：Redis、Postgresql、Gitlab 核心程序，实际上我们只要将这 3 个应用分别启动起来，然后加上对应的配置就可以很方便的安装 Gitlab 了，我们这里选择使用的镜像不是官方的，而是 Gitlab 容器化中使用非常多的一个第三方镜像：sameersbn/gitlab，基本上和官方保持同步更新，地址：http://www.damagehead.com/docker-gitlab/

如果我们已经有可使用的 Redis 或 Postgresql 服务的话，那么直接配置在 Gitlab 环境变量中即可，如果没有的话就单独部署,我们这里为了展示 gitlab 部署的完整性，还是分开部署。
为了提高数据库的性能，我们这里也没有使用共享存储之类的，而是直接用的 Local PV 将应用固定到一个节点上：
