/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  experimental: {
    serverComponentsExternalPackages: ['snowflake-sdk'],
  },
};
module.exports = nextConfig;
