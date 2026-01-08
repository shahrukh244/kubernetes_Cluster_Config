resource kube {
  protocol C;

  startup {
    wfc-timeout 15;
    degr-wfc-timeout 60;
  }

  net {
    cram-hmac-alg sha1;
    shared-secret "kube-drbd-secret";
  }

  on svc-1.kube.lan {
    device    /dev/drbd0;
    disk      /dev/nvme0n2;
    address   10.0.0.11:7789;
    meta-disk internal;
  }

  on svc-2.kube.lan {
    device    /dev/drbd0;
    disk      /dev/nvme0n2;
    address   10.0.0.12:7789;
    meta-disk internal;
  }
}
