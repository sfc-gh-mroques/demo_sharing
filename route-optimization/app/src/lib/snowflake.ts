import snowflake from 'snowflake-sdk';
import fs from 'fs';
import crypto from 'crypto';

snowflake.configure({ logLevel: 'ERROR' });

let connectionPool: any = null;

function getPrivateKey(): string {
  const keyPath = process.env.SNOWFLAKE_PRIVATE_KEY_PATH!;
  const keyContent = fs.readFileSync(keyPath, 'utf-8');
  const privateKey = crypto.createPrivateKey({
    key: keyContent,
    format: 'pem',
    passphrase: '',
  });
  return privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;
}

function getConnectionConfig(): any {
  // SPCS mode: use internal OAuth token provided by Snowflake
  const tokenPath = '/snowflake/session/token';
  if (fs.existsSync(tokenPath)) {
    const token = fs.readFileSync(tokenPath, 'utf-8');
    console.log('[Snowflake] Using SPCS internal OAuth token');
    const config: any = {
      account: process.env.SNOWFLAKE_ACCOUNT!,
      authenticator: 'OAUTH',
      token: token,
      database: process.env.SNOWFLAKE_DATABASE!,
      schema: process.env.SNOWFLAKE_SCHEMA!,
      warehouse: process.env.SNOWFLAKE_WAREHOUSE!,
    };
    if (process.env.SNOWFLAKE_HOST) {
      config.host = process.env.SNOWFLAKE_HOST;
    }
    return config;
  }

  // Local mode: use JWT/key-pair auth
  return {
    account: process.env.SNOWFLAKE_ACCOUNT!,
    username: process.env.SNOWFLAKE_USER!,
    authenticator: 'SNOWFLAKE_JWT',
    privateKey: getPrivateKey(),
    database: process.env.SNOWFLAKE_DATABASE!,
    schema: process.env.SNOWFLAKE_SCHEMA!,
    warehouse: process.env.SNOWFLAKE_WAREHOUSE!,
    role: process.env.SNOWFLAKE_ROLE || 'ROUTE_OPTIMIZATION_ROLE',
  };
}

function getConnection(): Promise<any> {
  return new Promise((resolve, reject) => {
    if (connectionPool && connectionPool.isUp()) {
      resolve(connectionPool);
      return;
    }
    connectionPool = null;
    const config = getConnectionConfig();
    console.log('[Snowflake] Connecting to:', config.host || config.account, 'db:', config.database);
    const conn = snowflake.createConnection(config);
    conn.connect((err: any) => {
      if (err) {
        console.error('[Snowflake] Connection error:', err.message);
        reject(err);
      } else {
        console.log('[Snowflake] Connected successfully');
        connectionPool = conn;
        resolve(conn);
      }
    });
  });
}

export async function query(sql: string): Promise<any[]> {
  console.log('[Snowflake] Executing:', sql.substring(0, 100));
  const conn = await getConnection();
  return new Promise((resolve, reject) => {
    conn.execute({
      sqlText: sql,
      complete: (err: any, _stmt: any, rows: any[]) => {
        if (err) {
          console.error('[Snowflake] Query error:', err.message);
          connectionPool = null;
          reject(err);
        } else {
          resolve(rows || []);
        }
      },
    });
  });
}
