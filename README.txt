
From srv01 Run these commands

# To clone Repo
git clone https://github.com/shahrukh244/kubernetes_Cluster_Config.git

# To install Ansible-CLI Run Python Script (install-Ansible.py)
python3 kubernetes_Cluster_Config/service_Node_Config/service_Node-01/01-install-Ansible.py

# To Ping Localhost
ansible localhost -m ping
# To Ping All host form hosts file
ansible all -m ping

# To set IP run this script
python3 kubernetes_Cluster_Config/service_Node_Config/service_Node-01/02-set_ip.py
# system will Reboot in 15 sec

