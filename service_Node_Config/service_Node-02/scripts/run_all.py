---
- name: Prepare and run master node configuration
  hosts: localhost
  gather_facts: false

  vars:
    target_host: "svc-2.kube.lan"
    script_path: "{{ lookup('env', 'HOME') }}/kubernetes_Cluster_Config/service_Node_Config/service_Node-02/scripts/canLoginAsRoot.py"
    playbooks_dir: "{{ lookup('env', 'HOME') }}/kubernetes_Cluster_Config/service_Node_Config/service_Node-02/scripts/"

    playbook_files:
    "01-InstallAnsible.yaml",
    "02-hostnameSet.yaml",
    "03-setIP.yaml",
    "04-NAT.yaml",
    "05-rootLoginEnable.yaml",
    "06-rootPasswdChange.yaml",
    "07-sshKeyGen.yaml",
    "08-disableSwap.yaml",
    "09-disableUFW.yaml",
    "10-keepalived.yaml",
    "11-dhcp.yaml",
    "12-bind9.yaml",
    "13-ntp.yaml",
    "14-haproxy.yaml",
    "15-reboot.yaml",

  tasks:
    # --------------------------------------------------
    # Step 1: Initial SSH test
    # --------------------------------------------------
    - name: Test initial SSH connectivity as root
      ansible.builtin.command: >
        ssh -o BatchMode=yes
            -o ConnectTimeout=10
            -o StrictHostKeyChecking=no
            root@{{ target_host }} "echo OK"
      register: ssh_test_1
      failed_when: false
      changed_when: false

    # --------------------------------------------------
    # Step 2: Enable root login if needed
    # --------------------------------------------------
    - name: Run canLoginAsRoot.py if SSH failed
      ansible.builtin.command: python3 "{{ script_path }}"
      when: ssh_test_1.rc != 0
      register: script_result
      changed_when: true

    - name: Abort if canLoginAsRoot.py failed
      ansible.builtin.fail:
        msg: "canLoginAsRoot.py failed. Cannot proceed."
      when:
        - ssh_test_1.rc != 0
        - script_result.rc != 0

    # --------------------------------------------------
    # Step 3: Re-test SSH
    # --------------------------------------------------
    - name: Re-test SSH connectivity as root
      ansible.builtin.command: >
        ssh -o BatchMode=yes
            -o ConnectTimeout=10
            -o StrictHostKeyChecking=no
            root@{{ target_host }} "echo OK"
      register: ssh_test_2
      failed_when: ssh_test_2.rc != 0
      changed_when: false

    # --------------------------------------------------
    # Step 4: Run playbooks WITH 5s delay between each
    # --------------------------------------------------
    - name: Run playbooks sequentially with 5s hold
      ansible.builtin.shell: |
        ansible-playbook {{ playbooks_dir }}/{{ item }}
        sleep 5
      loop: "{{ playbook_files }}"
      changed_when: true
