// The binding stays in the URL fragment: it is never sent to this endpoint.
export const restorePage = `<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>WeVault 恢复文件</title>
<style>body{font:17px system-ui,sans-serif;color:#172333;background:#f4f6fa;margin:0;padding:8vh 24px}main{max-width:620px;margin:auto;background:white;border-radius:20px;padding:36px}h1{font-size:30px}p{line-height:1.7}a,button{display:inline-block;border:0;border-radius:9px;padding:13px 18px;background:#245bcc;color:white;font:inherit;text-decoration:none;cursor:pointer;margin:8px 8px 8px 0}input{box-sizing:border-box;width:100%;padding:12px;font:13px ui-monospace,monospace;border:1px solid #aab3c0;border-radius:8px}#status{color:#586475}[hidden]{display:none}</style>
<main><h1>恢复归档文件</h1><p>在归档时使用的 Mac 上打开 WeVault，查看文件并选择恢复位置。</p>
<div id="actions" hidden><a id="open">打开 WeVault 恢复中心</a><p>如果浏览器未打开应用，可复制下方编号，在 WeVault 恢复中心粘贴并点击“定位”。</p><input id="binding" readonly aria-label="归档恢复编号"><button id="copy" type="button">复制恢复编号</button></div>
<p id="status" role="status">链接缺少完整恢复编号。请从占位文件重新打开链接，或在 WeVault 中选择归档记录。</p></main>
<script src="/restore.js" defer></script></html>`;

export const restoreScript = `"use strict";
const id = location.hash.slice(1);
if (/^binding-([a-f0-9]{32}|[a-f0-9]{64})$/.test(id)) {
  document.getElementById("actions").hidden = false;
  document.getElementById("binding").value = id;
  document.getElementById("open").href = "wevault://restore/" + id;
  const status = document.getElementById("status");
  status.textContent = "打开应用只会定位记录；恢复操作将在应用内进行。";
  document.getElementById("copy").addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(id); status.textContent = "已复制。请在 WeVault 恢复中心粘贴并点击定位。"; }
    catch { document.getElementById("binding").select(); status.textContent = "请按 Command+C 复制选中的编号。"; }
  });
}`;
