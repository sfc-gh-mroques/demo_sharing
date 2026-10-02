// Startup script: test Snowflake connectivity then start Next.js server
const fs = require('fs');

async function testConnection() {
  console.log('[Startup] Testing Snowflake connectivity...');
  console.log('[Startup] Account:', process.env.SNOWFLAKE_ACCOUNT);
  console.log('[Startup] Host:', process.env.SNOWFLAKE_HOST || '(auto-derived from account locator — recommended)');
  console.log('[Startup] Database:', process.env.SNOWFLAKE_DATABASE);

  const tokenPath = '/snowflake/session/token';
  if (!fs.existsSync(tokenPath)) {
    console.log('[Startup] No SPCS token found - skipping connection test (local mode)');
    return;
  }

  const token = fs.readFileSync(tokenPath, 'utf-8');
  console.log('[Startup] SPCS token found, length:', token.length);

  const snowflake = require('snowflake-sdk');
  snowflake.configure({ logLevel: 'ERROR' });

  return new Promise((resolve) => {
    const config = {
      account: process.env.SNOWFLAKE_ACCOUNT,
      authenticator: 'OAUTH',
      token: token,
      database: process.env.SNOWFLAKE_DATABASE,
      schema: process.env.SNOWFLAKE_SCHEMA,
      warehouse: process.env.SNOWFLAKE_WAREHOUSE,
    };
    if (process.env.SNOWFLAKE_HOST) {
      config.host = process.env.SNOWFLAKE_HOST;
    }
    const conn = snowflake.createConnection(config);

    conn.connect((err) => {
      if (err) {
        console.error('[Startup] Snowflake connection FAILED:', err.message);
      } else {
        console.log('[Startup] Snowflake connection SUCCESS');
        conn.execute({
          sqlText: 'SELECT CURRENT_USER() AS u, CURRENT_ROLE() AS r, CURRENT_DATABASE() AS d',
          complete: (err2, stmt, rows) => {
            if (err2) {
              console.error('[Startup] Test query failed:', err2.message);
            } else {
              console.log('[Startup] Connected as:', JSON.stringify(rows[0]));
            }
            conn.destroy(() => {});
            resolve();
          }
        });
        return;
      }
      resolve();
    });
  });
}

testConnection().then(() => {
  console.log('[Startup] Starting Next.js server...');
  require('./server.js');
}).catch((e) => {
  console.error('[Startup] Unexpected error:', e.message);
  require('./server.js');
});
