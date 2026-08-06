{ packageFor }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    getExe
    hasPrefix
    mkEnableOption
    mkIf
    mkOption
    optional
    types
    ;

  cfg = config.services.honk;
  configPath = if cfg.configFile != null then cfg.configFile else "/etc/honk/config.dae";
in
{
  options.services.honk = {
    enable = mkEnableOption "honk, a Rust eBPF transparent proxy engine";

    package = mkOption {
      type = types.package;
      default = packageFor pkgs;
      defaultText = lib.literalExpression "inputs.honk.packages.\${pkgs.system}.honk";
      description = "The honk package to run.";
    };

    configFile = mkOption {
      type = types.nullOr (types.addCheck types.str (path: hasPrefix "/" path));
      default = null;
      example = "/run/secrets/honk/config.dae";
      description = ''
        Absolute runtime path to the dae-format configuration. Use this for
        configurations containing credentials or managed outside Nix.
      '';
    };

    config = mkOption {
      type = types.nullOr types.lines;
      default = null;
      description = ''
        dae-format configuration written to /etc/honk/config.dae. This value
        is stored in the world-readable Nix store; do not put secrets here.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--debug" ];
      description = "Extra command-line arguments passed to honk-core.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example.RUST_LOG = "info";
      description = "Additional environment variables for the service.";
    };

    assetsPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/var/lib/honk/assets";
      description = ''
        Directory containing geoip.dat and geosite.dat. When set, this is
        passed as DAE_LOCATION_ASSET, matching honk's geo-asset lookup.
      '';
    };

    openFirewall = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "opening honk's transparent-proxy port";
          port = mkOption {
            type = types.port;
            default = 12345;
            description = "TCP and UDP port to open when openFirewall.enable is set.";
          };
        };
      };
      default = { };
      description = "Optional firewall rule for the transparent-proxy port.";
    };

    stateDirectory = mkOption {
      type = types.str;
      default = "honk";
      description = ''
        Name of the systemd StateDirectory created below /var/lib. Point
        cache_file.path in the honk configuration here when persistence is
        desired.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.config == null) != (cfg.configFile == null);
        message = "services.honk: set exactly one of config or configFile.";
      }
    ];

    environment.etc."honk/config.dae" = mkIf (cfg.configFile == null) {
      source = pkgs.writeText "honk-config.dae" (if cfg.config == null then "" else cfg.config);
      mode = "0600";
    };

    networking.firewall = mkIf cfg.openFirewall.enable {
      allowedTCPPorts = [ cfg.openFirewall.port ];
      allowedUDPPorts = [ cfg.openFirewall.port ];
    };

    systemd.services.honk = {
      description = "honk transparent proxy engine";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      reloadTriggers =
        optional (cfg.config != null) cfg.config
        ++ optional (cfg.configFile != null) cfg.configFile;

      serviceConfig = {
        ExecStart = "${getExe cfg.package} --config ${lib.escapeShellArg configPath} ${lib.escapeShellArgs cfg.extraArgs}";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = cfg.stateDirectory;
        LimitMEMLOCK = "infinity";
        Environment =
          lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment
          ++ optional (cfg.assetsPath != null) "DAE_LOCATION_ASSET=${cfg.assetsPath}";
      };
    };
  };
}
