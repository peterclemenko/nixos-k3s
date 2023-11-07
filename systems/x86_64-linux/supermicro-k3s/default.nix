{ config, lib, pkgs, inputs, ... }:
let
  user = "nix";
  cpu = "intel";
  dnsName = "server02";
in
{
  imports = with inputs.self.nixosModules; [
    inputs.self.nixosRoles.k3s
    inputs.home-manager.nixosModules.home-manager
  ];

  hardware.cpu."${cpu}".updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  templates = {
    system = {
      bootEncrypted = {
        enable = true;
        disk = "/dev/disk/by-id/ata-SanDisk_SDSSDH3_512G_191805802811";
      };
    };
    services = {
      singleNodeCluster = {
        enable = true;
        fluxBootstrap.enable = true;
      };
    };
  };

  security.pki.certificateFiles = [
    ./secrets/ca-cert.crt
  ];  
  
  age.secrets = {
    flux-git-auth.file = ./secrets/flux-git-auth.yaml.age;
    flux-sops-age.file = ./secrets/flux-sops-age.yaml.age;
  };

  sops = {
    defaultSopsFile = ./secrets/secrets.sops.yaml;
    secrets.user-password.neededForUsers = true;
  };

  users = {
    groups = {
      data = { 
        name = "data"; 
        members = ["git" "${user}"]; 
        gid = 1000;
      };
    };
    users = {
      ${user} = {
        isNormalUser = true;
        description = "nix user";
        createHome = true;
        # use `mkpasswd -m sha-512 | tr -d '\n'` to get the password hash for your sops file
        passwordFile = config.sops.secrets.user-password.path;
        home = "/home/${user}";
        extraGroups = [
          "audit"
          "users"
          "sshusers"
          "storage"
          "wheel"
        ];
        openssh.authorizedKeys.keyFiles = [
          ./secrets/ssh.server02.lan.pub
        ];
      };
      git = {
        isNormalUser = true;
        uid = 1000;
        description = "git user";
        createHome = true;
        home = "/home/git";
        shell = "${pkgs.git}/bin/git-shell";
        passwordFile = config.sops.secrets.user-password.path;
        extraGroups = [
          "users"
          "sshusers"
        ];
        openssh.authorizedKeys.keyFiles = [
          ./secrets/ssh.server02.lan.pub
        ];
      };    
    };
  };

  home-manager = {
    extraSpecialArgs = { inherit inputs; };
    users = {
      ${user} = import ./home.nix;
    };
  };
  
  systemd.tmpfiles.rules = [
    "d /opt/k3s 0775 ${user} data -"
    "d /opt/k3s/data 0775 ${user} data -"
    "d /opt/k3s/data/pv 0775 ${user} data -"
    "d /mnt/backup 0775 ${user} data -"
    "d /mnt/backup/k3s 0775 ${user} data -"
    "d /mnt/backup/k3s/minio 0775 ${user} data -"
    "d /home/${user}/.kube 0775 ${user} data -"
    "d /var/lib/rancher/k3s/server/manifests 0775 root data -"
    "L /home/${user}/.kube/config  - - - - /etc/rancher/k3s/k3s.yaml"
    "L /var/lib/rancher/k3s/server/manifests/flux.yaml - - - - /etc/flux.yaml"
    "L /var/lib/rancher/k3s/server/manifests/flux-git-auth.yaml - - - - /run/agenix/flux-git-auth"
    "L /var/lib/rancher/k3s/server/manifests/flux-sops-age.yaml - - - - /run/agenix/flux-sops-age"                                  
  ];
  
  # required for deploy-rs
  nix.settings.trusted-users = [ "root" "${user}" ];

  # git url schmeas: 
  # - 'git@server02.lan:r/gitops-homelab.git'
  # - 'ssh://git@server02.lan/home/git/r/gitops-homelab.git'
  # - 'ssh://git@server02.lan/~/r/gitops-homelab.git' => ~ is not supported in flux git repo url!
  # flux git secret:
  # 1. flux create secret git flux-git-auth --url="ssh://git@${dnsName}.lan/~/r/gitops-homelab.git" --private-key-file={{ .PRIVATE_SSH_KEYFILE }} --export > flux-git-secret.yaml
  # 2. manually change the knwon_hosts to `ssh-keyscan ${dnsName}` ssh-ed25519 output
  # 3. encrypt yaml with age
  environment.etc."flux.yaml" = {
    mode = "0750";
    text = ''
      apiVersion: source.toolkit.fluxcd.io/v1
      kind: GitRepository
      metadata:
        name: flux-system
        namespace: flux-system
      spec:
        interval: 2m
        ref:
          branch: main
        secretRef:
          name: flux-git-auth
        url: ssh://git@${dnsName}.lan/home/git/r/nixos-k3s.git
      ---
      apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata:
        name: flux-system
        namespace: flux-system
      spec:
        interval: 2m
        path: ./kubernetes/flux
        prune: true
        wait: false
        sourceRef:
          kind: GitRepository
          name: flux-system
        decryption:
          provider: sops
          secretRef:
            name: sops-age
    '';
  };

  system.activationScripts.git-mirror.text = ''
    mkdir -p /opt/k3s/data/pv/gitea/git/respositories/r
    chown git:data /opt/k3s/data/pv/gitea/git/respositories/r 
    chmod 775 /opt/k3s/data/pv/gitea/git/respositories/r
    chmod g+s /opt/k3s/data/pv/gitea/git/respositories/r    
    ln -s -t /home/git /opt/k3s/data/pv/gitea/git/respositories/r 2>/dev/null || true
  '';
}
