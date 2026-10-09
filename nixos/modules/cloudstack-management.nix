{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.cloudstack.management;

  propertiesFormat = pkgs.formats.javaProperties { };
  jsonFormat = pkgs.formats.json { };

  # The package links scripts/vm/systemvm/id_rsa.cloud to the system VM key
  # kept in this home directory, and its launcher points the extensions path
  # at extensionsDir, so neither is configurable.
  stateDir = "/var/lib/cloudstack";
  homeDir = "${stateDir}/management";
  secretsDir = "${stateDir}/secrets";
  extensionsDir = "${stateDir}/extensions";
  mountDir = "${stateDir}/mnt";
  logDir = "/var/log/cloudstack/management";
  confDir = "/run/cloudstack-management/conf";
  credentialsDir = "/run/credentials/cloudstack-management.service";
  usageConfDir = "/run/cloudstack-usage/conf";
  usageSanityCheckFile = "/usr/local/libexec/sanity-check-last-id";

  share = "${cfg.package}/share";
  inherit (cfg.package) jre;

  # Secrets that were not provided are generated on first start.
  secretFile = name: file: if file != null then file else "${secretsDir}/${name}";
  dbPasswordFile = secretFile "db-password" cfg.database.passwordFile;
  secretKeyFile = secretFile "secret-key" cfg.secretKeyFile;
  databaseSecretKeyFile = secretFile "database-secret-key" cfg.databaseSecretKeyFile;

  secretProperties = [
    "db.cloud.password"
    "db.usage.password"
    "db.simulator.password"
    "db.cloud.encrypt.secret"
    "https.keystore.password"
  ];

  webapp =
    let
      base = "${share}/cloudstack-management/webapp";
      overrides = jsonFormat.generate "cloudstack-ui-overrides.json" cfg.ui.settings;
    in
    if cfg.ui.settings == { } then
      base
    else
      # Jetty follows symlinks, so only config.json needs to be a real file.
      pkgs.runCommand "cloudstack-management-webapp"
        {
          nativeBuildInputs = [
            pkgs.jq
            pkgs.lndir
          ];
        }
        ''
          mkdir "$out"
          lndir -silent ${base} "$out"
          rm "$out/config.json"
          jq -s '.[0] * .[1]' ${base}/config.json ${overrides} > "$out/config.json"
        '';

  # Commands the management server runs through sudo, from upstream's
  # server/conf/cloudstack-sudoers.in, see sudo-commands.nix.
  sudo = pkgs.callPackage ../../pkgs/cloudstack/sudo-commands.nix { inherit jre; };
  sudoPackages = sudo.packages;
  sudoCommands = lib.unique (lib.attrValues sudo.commands);
  sudoRule = {
    users = [ "cloud" ];
    runAs = "root";
    commands = map (command: {
      inherit command;
      options = [ "NOPASSWD" ];
    }) sudoCommands;
  };

  # Tools the management server and its scripts call.
  runtimePackages =
    sudoPackages
    ++ (with pkgs; [
      bash
      bzip2
      cdrkit
      curl
      diffutils
      file
      gawk
      gnugrep
      gnused
      gnutar
      gzip
      iproute2
      ipmitool
      openssh
      procps
      python3
      unzip
      wget
      which
    ])
    ++ cfg.extraPackages;

  # The package's metadata.ini, with the given templates next to it.
  systemVmTemplatesDir = pkgs.linkFarm "cloudstack-systemvm-templates" (
    [
      {
        name = "metadata.ini";
        path = "${share}/cloudstack-management/templates/systemvm/metadata.ini";
      }
    ]
    ++ map (template: {
      inherit (template) name;
      path = template;
    }) cfg.systemVmTemplates
  );

  mysqlClient =
    if cfg.database.createLocally then config.services.mysql.package else pkgs.mariadb.client;

  databases = [
    "cloud"
    "cloud_usage"
  ]
  ++ lib.optional cfg.simulator.enable "simulator";

  # Shell code that sets `mysql` (the client), `password` (the database
  # password, read from passwordFile, a shell word) and defines `mysql_cloud`,
  # a client logged in as the database user. Its option file goes into the
  # unit's RuntimeDirectory.
  mysqlClientSetup = passwordFile: ''
    # MariaDB 11 deprecates the `mysql` name; MySQL only has that one.
    mysql=$(command -v mariadb || command -v mysql)

    password=$(< ${passwordFile})
    cnf_password=$(printf '%s' "$password" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    cat > "$RUNTIME_DIRECTORY/client.cnf" <<EOF
    [client]
    host=${cfg.database.host}
    port=${toString cfg.database.port}
    user=${cfg.database.user}
    password="$cnf_password"
    EOF
    mysql_cloud() {
      "$mysql" --defaults-extra-file="$RUNTIME_DIRECTORY/client.cnf" "$@"
    }
  '';

  # The connection entries that cloudstack-setup-databases writes for the
  # cloud and usage databases.
  databaseConnection = name: {
    "db.${name}.username" = cfg.database.user;
    "db.${name}.host" = cfg.database.host;
    "db.${name}.port" = cfg.database.port;
  };

  # Upstream's configuration file, as shipped in the package, with the
  # entries of settings in place of its entries with the same keys. The
  # secrets go in when the service starts.
  layeredProperties =
    file: settings:
    pkgs.runCommand "cloudstack-management-${file}" { } ''
      ${pkgs.gawk}/bin/awk -f ${./merge-properties.awk} \
        ${propertiesFormat.generate file settings} ${share}/cloudstack-management/conf/${file} > "$out"
    '';
  dbProperties = layeredProperties "db.properties" cfg.settings.db;
  serverProperties = layeredProperties "server.properties" cfg.settings.server;
  environmentProperties = layeredProperties "environment.properties" cfg.settings.environment;

  # Shell code for a unit with the database credentials (LoadCredential), run
  # with `set -euo pipefail`: defines `property KEY CREDENTIAL`, which prints
  # a .properties entry from a credential, and `withSecrets BASE OUT`, which
  # writes BASE to OUT with the entries read from stdin in place of BASE's
  # entries with the same keys. Then writes db.properties, with the secrets,
  # into dir.
  writeDbProperties = dir: ''
    # Java reads .properties files as ISO-8859-1, so secrets should be ASCII.
    property() {
      local value
      value=$(< "$CREDENTIALS_DIRECTORY/$2")
      if [[ $value == *$'\n'* ]]; then
        echo "error: credential $2 must be a single line" >&2
        exit 1
      fi
      printf '%s=%s\n' "$1" "''${value//\\/\\\\}"
    }
    withSecrets() {
      ${pkgs.gawk}/bin/awk -f ${./merge-properties.awk} - "$1" > "$2"
    }

    {
      property db.cloud.password db-password
      property db.usage.password db-password
      property db.cloud.encrypt.secret database-secret-key
      ${lib.optionalString cfg.simulator.enable "property db.simulator.password db-password"}
    } | withSecrets ${dbProperties} ${dir}/db.properties
  '';

  # The credentials behind writeDbProperties, and the encryption key file.
  databaseCredentials = [
    "db-password:${dbPasswordFile}"
    "secret-key:${secretKeyFile}"
    "database-secret-key:${databaseSecretKeyFile}"
  ];

  settingsOption =
    file: extraDescription:
    lib.mkOption {
      type = lib.types.submodule { freeformType = propertiesFormat.type; };
      default = { };
      description = ''
        Entries of {file}`${file}`, in place of the entries of upstream's file
        with the same keys (upstream's other entries are kept). The defaults
        set what upstream's setup tools would, from this module's options.
        ${extraDescription}
      '';
    };
in
{
  options.services.cloudstack.management = {
    enable = lib.mkEnableOption "the Apache CloudStack management server";

    package = lib.mkOption {
      type = lib.types.package;
      default =
        pkgs.cloudstack-management or (pkgs.callPackage ../../pkgs/cloudstack { }).cloudstack-management;
      defaultText = lib.literalExpression "pkgs.cloudstack-management";
      description = "The CloudStack management server package.";
    };

    nodeAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "192.0.2.10";
      description = ''
        Address of this management server for other management servers in the
        cluster ({file}`db.properties`: `cluster.node.IP`). Set a routable
        address for anything beyond a single-node test setup.
      '';
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "127.0.0.1";
      description = ''
        Address the API and web UI listen on ({file}`server.properties`:
        `bind.interface`). `null` listens on all addresses.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "HTTP port of the API and web UI, served under `/client`.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the HTTP(S) ports, the port agents and system VMs connect to
        (8250) and the cluster port of the management servers (9090).
      '';
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run a local MySQL-compatible server (MariaDB unless
          {option}`services.mysql.package` says otherwise) and create the
          `cloud` and `cloud_usage` databases and the database user.
        '';
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "Database host.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3306;
        description = "Database port.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "cloud";
        description = ''
          Database user. With a remote database it needs all privileges on
          the `cloud` and `cloud_usage` databases and the global `PROCESS`
          privilege.
        '';
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/secrets/cloudstack-db-password";
        description = ''
          File containing the database password; it must not be in the Nix
          store. With a local database and `null`, a random password is
          generated in {file}`${secretsDir}/db-password`.
        '';
      };
    };

    secretKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File containing the management server secret key (upstream's
        {file}`/etc/cloudstack/management/key`), used to decrypt `ENC(...)`
        values in the properties files. Generated in
        {file}`${secretsDir}/secret-key` if `null`.
      '';
    };

    databaseSecretKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File containing the key that encrypts sensitive values stored in the
        database (`db.cloud.encrypt.secret`), either plain or as `ENC(...)`
        encrypted with the secret key. Generated in
        {file}`${secretsDir}/database-secret-key` if `null`.

        Back it up together with the database: encrypted values cannot be
        recovered without it.
      '';
    };

    https = {
      enable = lib.mkEnableOption "HTTPS on the embedded Jetty server";

      port = lib.mkOption {
        type = lib.types.port;
        default = 8443;
        description = "HTTPS port of the API and web UI.";
      };

      keystoreFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Java keystore (JKS or PKCS12) holding the server certificate.";
      };

      keystorePasswordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "File containing the keystore password.";
      };
    };

    javaOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-Xmx4G" ];
      description = ''
        Extra JVM options. They come after upstream's (its
        {file}`packaging/systemd/cloudstack-management.default`), so they
        override them. They are word-split, so they cannot contain spaces.
      '';
    };

    logConfig = lib.mkOption {
      type = lib.types.path;
      default = "${share}/cloudstack-management/conf/log4j-cloud.xml";
      defaultText = lib.literalExpression ''"''${cfg.package}/share/cloudstack-management/conf/log4j-cloud.xml"'';
      description = ''
        Log4j 2 configuration. The default logs to
        {file}`${logDir}/management-server.log` and {file}`apilog.log`.
      '';
    };

    settings = {
      db = settingsOption "db.properties" ''
        The passwords and the database encryption secret come from the secret
        files and cannot be set here.
      '';
      server = settingsOption "server.properties" "";
      environment = settingsOption "environment.properties" "";
    };

    ui.settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      example = {
        appTitle = "My Cloud";
        docBase = "https://docs.cloudstack.apache.org/en/4.23.0.0";
      };
      description = ''
        Values merged into the web UI's {file}`config.json` (branding, API
        servers, documentation links, ...).
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.jq ]";
      description = ''
        Extra packages in the management server's PATH, e.g. for extension
        scripts.
      '';
    };

    systemVmTemplates = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ cloudstackPackages.systemvmTemplates.kvm-x86_64 ]";
      description = ''
        System VM templates that the server copies to new secondary storage,
        named as in its {file}`metadata.ini`, e.g. from
        `cloudstackPackages.systemvmTemplates`. The server downloads the ones
        it lacks for the zone's hypervisors from download.cloudstack.org; this
        is for servers without that access, or to download them only once.
      '';
    };

    simulator.enable = lib.mkEnableOption ''
      the simulator hypervisor, which simulates hosts, storage and system VMs
      so that zones can be deployed without hardware (hosts are added with
      URLs such as `http://sim/c0/h0`). It also replaces the NFS secondary
      storage provider, so it is for development and testing only.

      It uses a `simulator` database, which must already exist when the
      database is not created locally. Its template and hypervisor
      capabilities are loaded by `cloudstack-management-simulator.service`
      once the server has upgraded the schema; wait for that unit before
      adding a zone
    '';

    usage = {
      enable = lib.mkEnableOption ''
        the usage server on this host, `cloudstack-usage.service`, which turns
        the management server's usage events into usage records (the
        `listUsageRecords` API). It uses the management server's database
        settings and secrets, and starts once the server has upgraded the
        schema. Its job runs daily by default, as set by the global settings
        `usage.stats.job.exec.time` and `usage.stats.job.aggregation.range`,
        which it reads when it starts
      '';

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.cloudstack-usage or (pkgs.callPackage ../../pkgs/cloudstack { }).cloudstack-usage;
        defaultText = lib.literalExpression "pkgs.cloudstack-usage";
        description = "The CloudStack usage server package.";
      };

      javaOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "-Xmx4g" ];
        description = ''
          Extra JVM options of the usage server. They come after upstream's
          (its {file}`packaging/systemd/cloudstack-usage.default`), so they
          override them. They are word-split, so they cannot contain spaces.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.security.sudo.enable || config.security.sudo-rs.enable;
        message = "services.cloudstack.management needs sudo (security.sudo or security.sudo-rs).";
      }
      {
        assertion =
          cfg.database.createLocally
          -> lib.elem cfg.database.host [
            "localhost"
            "127.0.0.1"
          ];
        message = "services.cloudstack.management.database.createLocally needs database.host = \"localhost\".";
      }
      {
        assertion = cfg.database.createLocally || cfg.database.passwordFile != null;
        message = "services.cloudstack.management.database.passwordFile must be set for a remote database.";
      }
      {
        assertion =
          cfg.https.enable -> cfg.https.keystoreFile != null && cfg.https.keystorePasswordFile != null;
        message = "services.cloudstack.management.https needs keystoreFile and keystorePasswordFile.";
      }
      {
        assertion = lib.all (
          key: !(cfg.settings.db ? ${key} || cfg.settings.server ? ${key})
        ) secretProperties;
        message = "services.cloudstack.management.settings must not contain ${lib.concatStringsSep ", " secretProperties}; use the *File options.";
      }
    ];

    # What upstream's cloudstack-setup-databases writes into db.properties,
    # and what this module's options and paths decide. Everything else comes
    # from upstream's files, see settings.
    services.cloudstack.management.settings = {
      db = lib.mapAttrs (_: lib.mkDefault) (
        {
          "cluster.node.IP" = cfg.nodeAddress;
          # The key file and the database secret are used with encryption
          # on; the key file is read from the configuration directory.
          "db.cloud.encryption.type" = "file";
          "db.cloud.encryptor.version" = "V2";
        }
        // databaseConnection "cloud"
        // databaseConnection "usage"
        // lib.optionalAttrs cfg.simulator.enable (databaseConnection "simulator")
      );

      server = lib.mapAttrs (_: lib.mkDefault) (
        {
          "http.port" = cfg.port;
          "https.enable" = cfg.https.enable;
          "https.port" = cfg.https.port;
          "webapp.dir" = webapp;
        }
        // lib.optionalAttrs (cfg.listenAddress != null) {
          "bind.interface" = cfg.listenAddress;
        }
        // lib.optionalAttrs cfg.https.enable {
          "https.keystore" = "${credentialsDir}/https-keystore";
        }
      );

      environment = lib.mapAttrs (_: lib.mkDefault) {
        # The module's state directory.
        "mount.parent" = mountDir;
      };
    };

    users.users.cloud = {
      isSystemUser = true;
      group = "cloud";
      # Must be named "cloud": only then does the management server create the
      # system VM SSH key pair (in ~/.ssh).
      home = homeDir;
      description = "Apache CloudStack management server";
    };
    users.groups.cloud = { };

    security.sudo.extraRules = lib.mkIf config.security.sudo.enable [ sudoRule ];
    security.sudo-rs.extraRules = lib.mkIf config.security.sudo-rs.enable [ sudoRule ];

    # Secondary storage (and system VM template seeding) uses NFS mounts.
    boot.supportedFilesystems.nfs = true;

    services.mysql = lib.mkIf cfg.database.createLocally {
      enable = true;
      package = lib.mkDefault pkgs.mariadb;
      # Recommended by the CloudStack installation guide.
      settings.mysqld = {
        innodb_rollback_on_timeout = lib.mkDefault 1;
        innodb_lock_wait_timeout = lib.mkDefault 600;
        max_connections = lib.mkDefault 350;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall (
      [
        cfg.port
        8250
        9090
      ]
      ++ lib.optional cfg.https.enable cfg.https.port
    );

    # Upstream ships CloudMonkey (cmk) with the management server.
    environment.systemPackages = [ pkgs.cloudmonkey ];

    systemd.services.cloudstack-management-init = {
      description = "Apache CloudStack management server secrets and database";
      after = [ "network-online.target" ] ++ lib.optional cfg.database.createLocally "mysql.service";
      wants = [ "network-online.target" ];
      requires = lib.optional cfg.database.createLocally "mysql.service";
      path = [
        mysqlClient
        pkgs.coreutils
        pkgs.gnused
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "cloudstack/secrets";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "cloudstack-management-init";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
      };
      script = ''
        set -euo pipefail

        generate() {
          if [ ! -s "${secretsDir}/$1" ]; then
            echo "Generating ${secretsDir}/$1"
            head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${secretsDir}/$1"
          fi
        }
        ${lib.optionalString (cfg.database.passwordFile == null) "generate db-password"}
        ${lib.optionalString (cfg.secretKeyFile == null) "generate secret-key"}
        ${lib.optionalString (cfg.databaseSecretKeyFile == null) "generate database-secret-key"}

        ${mysqlClientSetup (lib.escapeShellArg dbPasswordFile)}
      ''
      + lib.optionalString cfg.database.createLocally ''
        # Replaces upstream's create-database*.sql, which drop and recreate.
        sql_password=$(printf '%s' "$password" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")
        {
          for db in ${toString databases}; do
            echo "CREATE DATABASE IF NOT EXISTS $db;"
          done
          for host in localhost 127.0.0.1 ::1; do
            user="'${cfg.database.user}'@'$host'"
            echo "CREATE USER IF NOT EXISTS $user IDENTIFIED BY '$sql_password';"
            echo "ALTER USER $user IDENTIFIED BY '$sql_password';"
            for db in ${toString databases}; do
              echo "GRANT ALL ON $db.* TO $user;"
            done
            echo "GRANT PROCESS ON *.* TO $user;"
          done
        } | "$mysql" --user=root
      ''
      + ''
        count_tables() {
          mysql_cloud --batch --skip-column-names \
            -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$1'"
        }

        # Load the base schema (CloudStack 4.0) into an empty database; the
        # management server upgrades it to its own version when it starts.
        tables=$(count_tables cloud)
        if [ "$tables" -eq 0 ]; then
          echo "Loading the initial CloudStack database schema"
          for script in create-schema create-schema-premium server-setup templates; do
            mysql_cloud < ${share}/cloudstack-management/setup/$script.sql
          done
        fi
      ''
      + lib.optionalString cfg.simulator.enable ''
        tables=$(count_tables simulator)
        if [ "$tables" -eq 0 ]; then
          echo "Loading the simulator database schema"
          mysql_cloud < ${share}/cloudstack-management/setup/create-schema-simulator.sql
        fi
      '';
    };

    systemd.services.cloudstack-management = {
      description = "Apache CloudStack management server";
      wantedBy = [ "multi-user.target" ];
      requires = [ "cloudstack-management-init.service" ];
      after = [
        "network-online.target"
        "cloudstack-management-init.service"
      ];
      wants = [ "network-online.target" ];

      # /run/wrappers (sudo) goes last, see sudoPackages.
      path = runtimePackages ++ [ "/run/wrappers" ];

      environment = {
        CLOUDSTACK_CONF_DIR = confDir;
        JAVA_OPTS = lib.concatStringsSep " " (
          cfg.javaOptions
          # Overrides the launcher's default.
          ++ lib.optional (
            cfg.systemVmTemplates != [ ]
          ) "-Dcloudstack.systemvm.templates.path=${systemVmTemplatesDir}/"
        );
      }
      // lib.optionalAttrs cfg.simulator.enable {
        CLOUDSTACK_EXTRA_CLASSPATH = "${share}/cloudstack-management/simulator/*";
      };

      # Assembles the configuration directory, upstream's
      # /etc/cloudstack/management: the files shipped in the package, with
      # the settings and the credentials.
      preStart = ''
        set -euo pipefail
        umask 0077

        rm -rf ${confDir}
        mkdir ${confDir}
        cp -r ${share}/cloudstack-management/conf/. ${confDir}/
        chmod -R u+w ${confDir}
        ${writeDbProperties confDir}
        {
          ${lib.optionalString cfg.https.enable "property https.keystore.password https-keystore-password"}
          true
        } | withSecrets ${serverProperties} ${confDir}/server.properties
        cp ${environmentProperties} ${confDir}/environment.properties
        cp ${cfg.logConfig} ${confDir}/log4j-cloud.xml
        cp ${credentialsDir}/secret-key ${confDir}/key

        # Refresh the bundled sample extensions, like a package upgrade does;
        # other extensions are left alone.
        cp -r ${share}/cloudstack-management/extensions/. ${extensionsDir}/
        chmod -R u+w ${extensionsDir}
      '';

      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        User = "cloud";
        Group = "cloud";
        LoadCredential =
          databaseCredentials
          ++ lib.optionals cfg.https.enable [
            "https-keystore:${cfg.https.keystoreFile}"
            "https-keystore-password:${cfg.https.keystorePasswordFile}"
          ];
        StateDirectory = [
          "cloudstack/management"
          "cloudstack/mnt"
          "cloudstack/extensions"
        ];
        StateDirectoryMode = "0750";
        LogsDirectory = "cloudstack/management";
        LogsDirectoryMode = "0750";
        CacheDirectory = "cloudstack/management";
        RuntimeDirectory = "cloudstack-management";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = homeDir;
        UMask = "0022";
        # The JVM exits with 143 on SIGTERM.
        SuccessExitStatus = 143;

        # The management server runs mount, cp, ... through sudo, so it must
        # be able to gain privileges: no NoNewPrivileges=, and nothing that
        # implies it for a non-root service (SystemCallFilter=,
        # ProtectKernel*=, LockPersonality=, RestrictSUIDSGID=, ...).
        PrivateTmp = true;
        ProtectSystem = "full";
        ProtectHome = true;
        ProtectControlGroups = true;
      };
    };

    # Upstream's simulator seed data (templates.simulator.sql and
    # hypervisor_capabilities.simulator.sql) needs the current schema, which
    # the management server creates from the base schema on its first start.
    systemd.services.cloudstack-management-simulator = lib.mkIf cfg.simulator.enable {
      description = "Apache CloudStack simulator templates";
      wantedBy = [ "cloudstack-management.service" ];
      after = [ "cloudstack-management.service" ];
      path = [
        mysqlClient
        pkgs.coreutils
        pkgs.gnused
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # The database upgrade on the first start takes minutes.
        TimeoutStartSec = "1h";
        RuntimeDirectory = "cloudstack-management-simulator";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
      };
      script = ''
        set -euo pipefail

        ${mysqlClientSetup (lib.escapeShellArg dbPasswordFile)}
        query() {
          mysql_cloud --batch --skip-column-names -e "$1"
        }

        # The last upgrade step marks the package version as complete.
        echo "Waiting for the database upgrade to ${cfg.package.version}"
        while true; do
          upgraded=$(query "SELECT COUNT(*) FROM cloud.version WHERE version = '${cfg.package.version}' AND step = 'Complete'")
          [ "$upgraded" -gt 0 ] && break
          sleep 5
        done

        # The scripts insert fixed ids, so they only run once.
        loaded=$(query "SELECT COUNT(*) FROM cloud.vm_template WHERE unique_name = 'simulator-domR'")
        if [ "$loaded" -eq 0 ]; then
          echo "Loading the simulator templates and hypervisor capabilities"
          {
            echo "START TRANSACTION;"
            cat ${share}/cloudstack-management/setup/templates.simulator.sql
            cat ${share}/cloudstack-management/setup/hypervisor_capabilities.simulator.sql
            echo "COMMIT;"
          } | mysql_cloud
        fi
      '';
    };

    # The usage sanity check (global setting usage.sanity.check.interval, off
    # by default) keeps its state at this fixed path.
    systemd.tmpfiles.rules = lib.mkIf cfg.usage.enable [
      "d /usr/local/libexec 0755 root root - -"
      "f ${usageSanityCheckFile} 0644 cloud cloud - 1"
    ];

    # Upstream's package links the usage server's db.properties and key to
    # the management server's; this one writes the same files.
    systemd.services.cloudstack-usage = lib.mkIf cfg.usage.enable {
      description = "Apache CloudStack usage server";
      wantedBy = [ "multi-user.target" ];
      requires = [ "cloudstack-management-init.service" ];
      after = [
        "network-online.target"
        "cloudstack-management-init.service"
      ];
      wants = [ "network-online.target" ];

      path = [
        mysqlClient
        pkgs.coreutils
        pkgs.gnused
      ];

      environment = {
        CLOUDSTACK_CONF_DIR = usageConfDir;
        JAVA_OPTS = lib.concatStringsSep " " cfg.usage.javaOptions;
      };

      preStart = ''
        set -euo pipefail
        umask 0077

        # Upstream's /etc/cloudstack/usage, with the management server's
        # db.properties and key in place of the package's.
        rm -rf ${usageConfDir}
        mkdir ${usageConfDir}
        cp -r ${cfg.usage.package}/share/cloudstack-usage/conf/. ${usageConfDir}/
        chmod -R u+w ${usageConfDir}
        ${writeDbProperties usageConfDir}
        cp "$CREDENTIALS_DIRECTORY/secret-key" ${usageConfDir}/key
      '';

      # The usage server needs the schema of its own version and its job
      # settings, which the management server creates when it starts, the
      # settings after the schema: on a new installation, wait for both rather
      # than fail and restart.
      script = ''
        set -euo pipefail

        ${mysqlClientSetup ''"$CREDENTIALS_DIRECTORY/db-password"''}
        ready() {
          local ready
          ready=$(mysql_cloud --batch --skip-column-names -e "
            SELECT
              (SELECT COUNT(*) FROM cloud.version
                WHERE version = '${cfg.usage.package.version}' AND step = 'Complete') > 0
              AND (SELECT COUNT(*) FROM cloud.configuration
                WHERE name IN ('usage.stats.job.exec.time', 'usage.stats.job.aggregation.range')
                  AND value IS NOT NULL) = 2
          " 2>/dev/null) || return 1
          [ "$ready" = 1 ]
        }
        if ! ready; then
          echo "Waiting for the management server to upgrade the database to ${cfg.usage.package.version}"
          until ready; do
            sleep 10
          done
        fi

        exec ${lib.getExe cfg.usage.package}
      '';

      serviceConfig = {
        User = "cloud";
        Group = "cloud";
        LoadCredential = databaseCredentials;
        LogsDirectory = "cloudstack/usage";
        LogsDirectoryMode = "0750";
        RuntimeDirectory = "cloudstack-usage";
        RuntimeDirectoryMode = "0700";
        UMask = "0027";
        Restart = "always";
        RestartSec = "10s";
        # The JVM exits with 143 on SIGTERM.
        SuccessExitStatus = 143;

        ReadWritePaths = [ "-${usageSanityCheckFile}" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };
  };
}
