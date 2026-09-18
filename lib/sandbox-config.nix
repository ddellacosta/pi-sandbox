{
  bridge = "br-pi";
  tap = "pi-tap";
  subnet = "10.0.3.0/24";
  hostIp = "10.0.3.1";
  vmIp = "10.0.3.2";
  ollamaIp = "10.0.3.1";
  ollamaPort = 11434;
  dns = [ "9.9.9.9" "1.1.1.1" ];
  workspaceHostPath = "workspace";
  workspaceVmMountPoint = "/mnt/shared";
  piVersion = "0.84.2";
  vmMemoryMb = 4096;
  vmCores = 4;
  vmDiskSizeMb = 4096;
}
