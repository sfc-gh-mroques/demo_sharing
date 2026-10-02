spec:
  containers:
  - name: app
    image: __IMAGE_PATH__
    env:
      SNOWFLAKE_ACCOUNT: __ACCOUNT_LOCATOR__
      SNOWFLAKE_DATABASE: __DATABASE__
      SNOWFLAKE_SCHEMA: __SCHEMA__
      SNOWFLAKE_WAREHOUSE: __WAREHOUSE__
      CORTEX_AGENT_NAME: __DATABASE__.__SCHEMA__.ROUTES_AGENT
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 2000m
        memory: 4Gi
    readinessProbe:
      port: 8080
      path: /
  endpoints:
  - name: app
    port: 8080
    public: true
