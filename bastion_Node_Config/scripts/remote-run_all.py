---
- name: Prepare and run master node configuration
  hosts: localhost
  gather_facts: false

  vars:
    target_host: "bastion.kube.lan"
    script_path: "{{ lookup('env', 'HOME') }}/kubernetes_Cluster_Config/bastion_Node_Config/scripts/canLoginAsRoot.py"
    playbooks_dir: "{{ lookup('env', 'HOME') }}/kubernetes_Cluster_Config/bastion_Node_Config/scripts/"

    playbook_files:
    - "cloneRepo.yaml"
    - "01-InstallAnsible.yaml"
    - "02-hostnameSet.yaml"
    - "03-rootLoginEnable.yaml"
    - "04-rootPasswdChange.yaml"
    - "05-sshKeyGen.yaml"
    - "06-disableSwap.yaml"
    - "07-disableUFW.yaml"
    - "08-enable_ip_forwarding.yaml"
    - "09-configure_chrony.yaml"
    - "10-install_oc_cli.yaml"
    - "11-install_kubectl.yaml"
    - "12-install-nfs.yaml"
    - "13-reboot.yaml"

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
