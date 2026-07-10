export APP_CARAVAN_STORE_HEARTWOOD_V2_MARIADB_PASSWORD="$(derive_entropy "${app_entropy_identifier}-mariadb-password")"
export APP_CARAVAN_STORE_HEARTWOOD_V2_MARIADB_ROOT_PASSWORD="$(derive_entropy "${app_entropy_identifier}-mariadb-root-password")"
