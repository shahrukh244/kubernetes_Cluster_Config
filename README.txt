
From srv01 Run these commands

# To clone Repo
git clone https://github.com/shahrukh244/kubernetes_Cluster_Config.git

# To install Ansible-CLI Run Python Script (install-Ansible.py)
python3 kubernetes_Cluster_Config/service_Node_Config/service_Node-01/install-Ansible.py

# To Ping Localhost
ansible localhost -m ping
# To Ping All host form hosts file
ansible all -m ping

