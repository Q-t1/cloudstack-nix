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
  # server/conf/cloudstack-sudoers.in (secondary storage mounts, system VM
  # template seeding). sudo looks them up in the service PATH and matches the
  # result against these rules, so these packages come first in that PATH.
  sudoPackages = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.util-linux
    pkgs.qemu-utils
    jre
  ];
  sudoCommands = [
    "${pkgs.coreutils}/bin/mkdir"
    "${pkgs.coreutils}/bin/cp"
    "${pkgs.coreutils}/bin/chmod"
    "${pkgs.coreutils}/bin/touch"
    "${pkgs.coreutils}/bin/df"
    "${pkgs.coreutils}/bin/ls"
    "${pkgs.findutils}/bin/find"
    "${pkgs.util-linux}/bin/mount"
    "${pkgs.util-linux}/bin/umount"
    "${pkgs.qemu-utils}/bin/qemu-img"
    "${jre}/bin/keytool"
  ];
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

  mysqlClient =
    if cfg.database.createLocally then config.services.mysql.package else pkgs.mariadb.client;

  settingsOption =
    file: extraDescription:
    lib.mkOption {
      type = lib.types.submodule { freeformType = propertiesFormat.type; };
      default = { };
      description = ''
        Entries of {file}`${file}`, merged over defaults that follow upstream.
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
      default = [
        "-Xmx2G"
        "-XX:+UseParallelGC"
        "-XX:MaxGCPauseMillis=500"
        "-XX:+HeapDumpOnOutOfMemoryError"
        "-XX:HeapDumpPath=${logDir}"
        "-XX:ErrorFile=${logDir}/cloudstack-management.err"
        "-Djava.io.tmpdir=/var/tmp"
      ];
      description = "JVM options. They are word-split, so they cannot contain spaces.";
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

    services.cloudstack.management.settings = {
      db = lib.mapAttrs (_: lib.mkDefault) {
        "cluster.node.IP" = cfg.nodeAddress;
        "cluster.servlet.port" = 9090;
        "region.id" = 1;

        "db.cloud.username" = cfg.database.user;
        "db.cloud.host" = cfg.database.host;
        "db.cloud.port" = cfg.database.port;
        "db.cloud.name" = "cloud";
        "db.cloud.driver" = "jdbc:mysql";
        "db.cloud.uri" = "";
        "db.cloud.connectionPoolLib" = "hikaricp";
        "db.cloud.maxActive" = 250;
        "db.cloud.maxIdle" = 30;
        "db.cloud.maxWait" = 600000;
        "db.cloud.minIdleConnections" = 5;
        "db.cloud.connectionTimeout" = 30000;
        "db.cloud.keepAliveTime" = 600000;
        "db.cloud.validationQuery" = "/* ping */ SELECT 1";
        "db.cloud.testOnBorrow" = true;
        "db.cloud.testWhileIdle" = true;
        "db.cloud.timeBetweenEvictionRunsMillis" = 40000;
        "db.cloud.minEvictableIdleTimeMillis" = 240000;
        "db.cloud.poolPreparedStatements" = false;
        "db.cloud.url.params" =
          "prepStmtCacheSize=517&cachePrepStmts=true&sessionVariables=sql_mode='STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION'&serverTimezone=UTC";
        "db.cloud.useSSL" = false;
        "db.cloud.keyStore" = "";
        "db.cloud.keyStorePassword" = "";
        "db.cloud.trustStore" = "";
        "db.cloud.trustStorePassword" = "";
        # Encryption must be on for the database secret to be used; the key
        # file is read from the configuration directory.
        "db.cloud.encryption.type" = "file";
        "db.cloud.encryptor.version" = "V2";
        "db.cloud.replicas" = "localhost,localhost";
        "db.cloud.autoReconnect" = true;
        "db.cloud.failOverReadOnly" = false;
        "db.cloud.reconnectAtTxEnd" = true;
        "db.cloud.autoReconnectForPools" = true;
        "db.cloud.secondsBeforeRetrySource" = 3600;
        "db.cloud.queriesBeforeRetrySource" = 5000;
        "db.cloud.initialTimeout" = 3600;

        "db.usage.username" = cfg.database.user;
        "db.usage.host" = cfg.database.host;
        "db.usage.port" = cfg.database.port;
        "db.usage.name" = "cloud_usage";
        "db.usage.driver" = "jdbc:mysql";
        "db.usage.uri" = "";
        "db.usage.connectionPoolLib" = "hikaricp";
        "db.usage.maxActive" = 100;
        "db.usage.maxIdle" = 30;
        "db.usage.maxWait" = 600000;
        "db.usage.minIdleConnections" = 5;
        "db.usage.connectionTimeout" = 30000;
        "db.usage.keepAliveTime" = 600000;
        "db.usage.url.params" = "serverTimezone=UTC";
        "db.usage.replicas" = "localhost,localhost";
        "db.usage.autoReconnect" = true;
        "db.usage.failOverReadOnly" = false;
        "db.usage.reconnectAtTxEnd" = true;
        "db.usage.autoReconnectForPools" = true;
        "db.usage.secondsBeforeRetrySource" = 3600;
        "db.usage.queriesBeforeRetrySource" = 5000;
        "db.usage.initialTimeout" = 3600;

        "db.ha.enabled" = false;
        "db.ha.loadBalanceStrategy" = "com.cloud.utils.db.StaticStrategy";
      };

      server = lib.mapAttrs (_: lib.mkDefault) (
        {
          "context.path" = "/client";
          "http.enable" = true;
          "http.port" = cfg.port;
          "session.timeout" = 30;
          "request.content.size" = 1048576;
          "request.max.form.keys" = 5000;
          "https.enable" = cfg.https.enable;
          "https.port" = cfg.https.port;
          "webapp.dir" = webapp;
          "access.log" = "${logDir}/access.log";
          "extensions.deployment.mode" = "production";
        }
        // lib.optionalAttrs (cfg.listenAddress != null) {
          "bind.interface" = cfg.listenAddress;
        }
        // lib.optionalAttrs cfg.https.enable {
          "https.keystore" = "${credentialsDir}/https-keystore";
        }
      );

      environment = lib.mapAttrs (_: lib.mkDefault) {
        "paths.script" = "${share}/cloudstack-common";
        "mount.parent" = mountDir;
        "cloud-stack-components-specification" = "components.xml";
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

        # MariaDB 11 deprecates the `mysql` name; MySQL only has that one.
        mysql=$(command -v mariadb || command -v mysql)

        generate() {
          if [ ! -s "${secretsDir}/$1" ]; then
            echo "Generating ${secretsDir}/$1"
            head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${secretsDir}/$1"
          fi
        }
        ${lib.optionalString (cfg.database.passwordFile == null) "generate db-password"}
        ${lib.optionalString (cfg.secretKeyFile == null) "generate secret-key"}
        ${lib.optionalString (cfg.databaseSecretKeyFile == null) "generate database-secret-key"}

        password=$(< ${lib.escapeShellArg dbPasswordFile})
      ''
      + lib.optionalString cfg.database.createLocally ''
        # Replaces upstream's create-database*.sql, which drop and recreate.
        sql_password=$(printf '%s' "$password" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")
        {
          echo "CREATE DATABASE IF NOT EXISTS cloud;"
          echo "CREATE DATABASE IF NOT EXISTS cloud_usage;"
          for host in localhost 127.0.0.1 ::1; do
            user="'${cfg.database.user}'@'$host'"
            echo "CREATE USER IF NOT EXISTS $user IDENTIFIED BY '$sql_password';"
            echo "ALTER USER $user IDENTIFIED BY '$sql_password';"
            echo "GRANT ALL ON cloud.* TO $user;"
            echo "GRANT ALL ON cloud_usage.* TO $user;"
            echo "GRANT PROCESS ON *.* TO $user;"
          done
        } | "$mysql" --user=root
      ''
      + ''
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

        # Load the base schema (CloudStack 4.0) into an empty database; the
        # management server upgrades it to its own version when it starts.
        tables=$(mysql_cloud --batch --skip-column-names \
          -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'cloud'")
        if [ "$tables" -eq 0 ]; then
          echo "Loading the initial CloudStack database schema"
          for script in create-schema create-schema-premium server-setup templates; do
            mysql_cloud < ${share}/cloudstack-management/setup/$script.sql
          done
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
        JAVA_OPTS = lib.concatStringsSep " " cfg.javaOptions;
      };

      # Assembles the configuration directory, which goes first on the
      # classpath, from the generated files and the credentials.
      preStart = ''
        set -euo pipefail
        umask 0077

        # A .properties entry from a credential. Java reads these files as
        # ISO-8859-1, so secrets should be ASCII.
        property() {
          local value
          value=$(< "${credentialsDir}/$2")
          if [[ $value == *$'\n'* ]]; then
            echo "error: credential $2 must be a single line" >&2
            exit 1
          fi
          printf '%s=%s\n' "$1" "''${value//\\/\\\\}"
        }

        rm -rf ${confDir}
        mkdir ${confDir}
        {
          cat ${propertiesFormat.generate "db.properties" cfg.settings.db}
          property db.cloud.password db-password
          property db.usage.password db-password
          property db.cloud.encrypt.secret database-secret-key
        } > ${confDir}/db.properties
        {
          cat ${propertiesFormat.generate "server.properties" cfg.settings.server}
          ${lib.optionalString cfg.https.enable "property https.keystore.password https-keystore-password"}
        } > ${confDir}/server.properties
        cp ${propertiesFormat.generate "environment.properties" cfg.settings.environment} \
          ${confDir}/environment.properties
        cp ${cfg.logConfig} ${confDir}/log4j-cloud.xml
        ln -s log4j-cloud.xml ${confDir}/log4j2.xml
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
        LoadCredential = [
          "db-password:${dbPasswordFile}"
          "secret-key:${secretKeyFile}"
          "database-secret-key:${databaseSecretKeyFile}"
        ]
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
  };
}
