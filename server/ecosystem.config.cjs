module.exports = {
  apps: [{
    name: "wevault-api-staging",
    script: "dist/index.js",
    interpreter: "/usr/bin/node",
    cwd: "/opt/wevault-api/current/server",
    instances: 1,
    exec_mode: "fork",
    autorestart: true,
    max_memory_restart: "300M",
    env: { NODE_ENV: "production", HOST: "127.0.0.1", PORT: "31061", DOTENV_CONFIG_PATH: "/etc/wevault-api/runtime.env" }
  }]
};
