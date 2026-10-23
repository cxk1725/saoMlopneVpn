#!/bin/bash
# ============================================================
#  SaoML 8.15 破解版安装脚本（卡密验证已移除）
#  原理：原版脚本对 sq.xq688.com.cn 的响应仅检查第 9 个字符
#        是否为 '0'，本版直接跳过全部验证流程。
#  用法：把本脚本与 xsaoml（第6层安装器，可用 analysis/stage6_xsaoml）
#        一起上传到 CentOS 7 x64 服务器任意目录，然后:
#        bash cracked_stage5.sh
# ============================================================
System_Check()
{
IP=`curl -s http://members.3322.org/dyndns/getip`;
echo
echo -e "您服务器IP是：\033[32m"$IP"\033[0m "
echo
echo -e "\033[32m[破解版] 授权验证已跳过，直接进入安装向导......\033[0m"
sleep 1

rm -rf /bin/xsaoml >/dev/null 2>&1
echo
echo -e "获取资源中..."
echo
# 优先使用同目录下的本地安装器（离线），否则联网下载原版资源
if [ -f ./xsaoml ]; then
    cp -f ./xsaoml /bin/xsaoml
else
    wget -q -O /bin/xsaoml http://mes.xq688.com.cn/public/saoml/8.15/xsaoml
fi
chmod 777 /bin/xsaoml
xsaoml
}
	Main()
{
	rm -rf /root/xxsaoml
	System_Check
     history -c
	return 0;
}


Main
exit 0;
