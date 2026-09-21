# Shared setup for unit tests: sources the libraries against a throw-away tree.
unit_setup() {
  export SSHUDP_TESTING=1
  export SSHUDP_LIB_HOME="$BATS_TEST_DIRNAME/../../lib"
  TMP="$(mktemp -d)"
  export SSHUDP_CONF_DIR="$TMP/etc" SSHUDP_STATE_DIR="$TMP/var" SSHUDP_INSTALL_DIR="$TMP/lib" \
    SSHUDP_BACKUP_DIR="$TMP/bak" SSHUDP_BIN_LINK="$TMP/bin-sshudp" SSHUDP_SYSTEMD_DIR="$TMP/systemd" \
    SSHUDP_SSHD_DROPIN_DIR="$TMP/dropin" NO_COLOR=1
  mkdir -p "$SSHUDP_CONF_DIR" "$SSHUDP_STATE_DIR/users" "$SSHUDP_STATE_DIR/state" "$SSHUDP_INSTALL_DIR" \
    "$SSHUDP_BACKUP_DIR" "$SSHUDP_SYSTEMD_DIR" "$SSHUDP_SSHD_DROPIN_DIR"
  local m
  for m in common validate config platform core firewall service users monitor client doctor backup update repair uninstall extras installer ui; do
    # shellcheck disable=SC1090
    source "$SSHUDP_LIB_HOME/$m.sh"
  done
}
unit_teardown() { rm -rf -- "$TMP"; }
