# rbw: fast unofficial Bitwarden CLI + in-memory agent, with optional Touch ID unlock.
#
# The Bitwarden account email is deliberately NOT declared here (this repo is public);
# set it once per machine with `rbw config set email <address>`. `~/.config/rbw/config.json`
# therefore stays a regular writable file and activation only pins the `pinentry` key.
#
# Touch ID unlock is opt-in: `rbw-touchid enroll` stores the master password in the
# login keyring (Secret Service). From then on `pinentry-rbw-touchid` answers rbw's
# "Master Password" prompt after a successful `fprintd-verify`, and falls back to the
# regular graphical pinentry when the fingerprint fails, on retries after a wrong
# password, and for every other prompt (2FA codes, API keys).
{
  config,
  lib,
  osConfig ? { },
  pkgs,
  ...
}:
let
  fallbackPinentry = lib.getExe pkgs.pinentry-qt;
  cfg = config.programs.omarchnix.rbw;
  hasFprintd = cfg.touchId;
  fprintdVerify = "${osConfig.services.fprintd.package or pkgs.fprintd}/bin/fprintd-verify";
  secretTool = "${pkgs.libsecret}/bin/secret-tool";
  secretAttrs = "service rbw-touchid account master-password";

  pinentryTouchid = pkgs.writeShellScriptBin "pinentry-rbw-touchid" ''
    set -u
    fallback=${fallbackPinentry}

    lookup() { ${secretTool} lookup ${secretAttrs} 2>/dev/null; }

    # Not enrolled (or explicitly disabled): behave exactly like the plain pinentry.
    if [ -n "''${RBW_TOUCHID_DISABLE:-}" ] || ! lookup >/dev/null; then
      exec "$fallback" "$@"
    fi

    # Assuan data lines must escape `%`, CR and LF.
    encode() {
      local s=$1
      s=''${s//%/%25}
      s=''${s//$'\r'/%0D}
      s=''${s//$'\n'/%0A}
      printf '%s' "$s"
    }

    buffered=()
    prompt=""
    retry=0

    ask_fallback() {
      local resp data err
      resp="$(printf '%s\n' "''${buffered[@]}" GETPIN BYE | "$fallback" "$@")"
      data="$(printf '%s\n' "$resp" | grep -m1 '^D ' || true)"
      if [ -n "$data" ]; then
        printf '%s\nOK\n' "$data"
      else
        err="$(printf '%s\n' "$resp" | grep -m1 '^ERR ' || true)"
        printf '%s\n' "''${err:-ERR 83886179 Operation cancelled <Pinentry>}"
      fi
    }

    touchid_ok() {
      ${pkgs.coreutils}/bin/timeout 30 ${fprintdVerify} 2>/dev/null | grep -q 'verify-match'
    }

    echo "OK Pleased to meet you"
    while IFS= read -r line; do
      line=''${line%$'\r'}
      case "''${line%% *}" in
        SETPROMPT)
          prompt=''${line#SETPROMPT }
          buffered+=("$line")
          echo OK
          ;;
        SETERROR)
          # rbw sets an error on attempts 2 and 3: the stored password was rejected.
          retry=1
          buffered+=("$line")
          echo OK
          ;;
        GETPIN)
          secret=""
          if [ "$retry" = 0 ] && [ "$prompt" = "Master Password" ] && touchid_ok && secret="$(lookup)" && [ -n "$secret" ]; then
            printf 'D %s\nOK\n' "$(encode "$secret")"
          else
            ask_fallback "$@"
          fi
          secret=""
          ;;
        GETINFO)
          if [ "$line" = "GETINFO pid" ]; then echo "D $$"; fi
          echo OK
          ;;
        BYE)
          echo OK
          exit 0
          ;;
        *)
          buffered+=("$line")
          echo OK
          ;;
      esac
    done
  '';

  rbwTouchid = pkgs.writeShellScriptBin "rbw-touchid" ''
    set -eu
    case "''${1:-status}" in
      enroll)
        echo "Stores your Bitwarden master password in the login keyring so rbw can"
        echo "unlock with Touch ID. Anything that can read the unlocked keyring can read it."
        ${secretTool} store --label="rbw master password (Touch ID unlock)" ${secretAttrs}
        echo "Enrolled. Run 'rbw lock && rbw unlock' to try it."
        ;;
      forget)
        ${secretTool} clear ${secretAttrs}
        echo "Removed the stored master password; rbw will prompt for it again."
        ;;
      status)
        if ${secretTool} lookup ${secretAttrs} >/dev/null 2>&1; then
          echo "enrolled"
        else
          echo "not enrolled"
        fi
        ;;
      *)
        echo "usage: rbw-touchid {enroll|forget|status}" >&2
        exit 2
        ;;
    esac
  '';

  # Guard shim: `bitwarden-cli` is gone, so `bw` points coding agents and muscle memory at rbw.
  useRbwInsteadShim = pkgs.writeShellScriptBin "bw" ''
    cat >&2 <<EOF
    warning: 'bw''${1:+ $1}' (bitwarden-cli) is not installed on this machine — use 'rbw' instead (agent-backed, no BW_SESSION):
      - unlock / sync:   rbw unlock ; rbw sync
      - list entries:    rbw list [--fields name,user,folder]
      - search:          rbw search <term>
      - get password:    rbw get <name> [user]      (--full for notes, --field <f>, --raw for JSON)
      - get TOTP code:   rbw code <name> [user]
      - add / generate:  rbw add <name> [user] ; rbw generate <len> [name] [user]
    Never print secret values into logs or chat; pipe them straight to the consumer.
    EOF
    exit 1
  '';

  pinentry = if hasFprintd then lib.getExe pinentryTouchid else fallbackPinentry;
in
{
  options.programs.omarchnix.rbw = {
    enable = lib.mkEnableOption "rbw (unofficial Bitwarden CLI with an in-memory agent) and a `bw` guard shim";
    touchId = lib.mkOption {
      type = lib.types.bool;
      default = osConfig.services.fprintd.enable or false;
      defaultText = lib.literalExpression "osConfig.services.fprintd.enable or false";
      description = "Offer opt-in Touch ID unlock (`rbw-touchid enroll`) through a fprintd-backed pinentry.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.rbw
      useRbwInsteadShim
    ]
    ++ lib.optional hasFprintd rbwTouchid;

    home.activation.rbwPinentry = config.lib.dag.entryAfter [ "writeBoundary" ] ''
      rbw_cfg="$HOME/.config/rbw/config.json"
      mkdir -p "$HOME/.config/rbw"
      if [ ! -s "$rbw_cfg" ] || [ -L "$rbw_cfg" ]; then
        rm -f "$rbw_cfg"
        printf '{}\n' > "$rbw_cfg"
      fi
      tmp_rbw="$(mktemp "$rbw_cfg.XXXXXX")"
      if ${pkgs.jq}/bin/jq --arg p ${lib.escapeShellArg pinentry} '.pinentry = $p' "$rbw_cfg" > "$tmp_rbw"; then
        chmod 600 "$tmp_rbw"
        mv "$tmp_rbw" "$rbw_cfg"
      else
        rm -f "$tmp_rbw"
      fi
    '';
  };
}
