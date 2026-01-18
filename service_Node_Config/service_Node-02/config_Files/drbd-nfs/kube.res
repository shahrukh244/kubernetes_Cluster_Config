resource kube {
  protocol C;

  startup {
    wfc-timeout 30;
    degr-wfc-timeout 15;
    outdated-wfc-timeout 10;
  }

  net {
    cram-hmac-alg sha256;
    shared-secret "kube-drbd-secret";
  }

  disk {
    fencing resource-only;
  }

  handlers {
    pri-on-incon-degr "echo o > /proc/sysrq-trigger ; halt -f";
    pri-lost-after-sb "echo o > /proc/sysrq-trigger ; halt -f";
    local-io-error    "echo o > /proc/sysrq-trigger ; halt -f";
  }

  on svc-1.kube.lan {
    device    /dev/drbd0;
    disk      /dev/drbd_vg/drbd_lv;
    address   10.0.0.11:7789;
    meta-disk internal;
  }

  on svc-2.kube.lan {
    device    /dev/drbd0;
    disk      /dev/drbd_vg/drbd_lv;
    address   10.0.0.12:7789;
    meta-disk internal;
  }
}
