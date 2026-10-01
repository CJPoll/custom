// Preloaded into @notionhq/notion-mcp-server by ai/bin/notion-athena-mcp
// (NODE_OPTIONS=--require). DND-1449.
//
// Server 2.5.x stopped sending a global Notion-Version header: it sources the
// header per operation from its OpenAPI spec, and only the page-markdown
// operations declare one (2026-03-11). Every other operation goes out with NO
// header. Most routes tolerate that; the comments route answers
// HTTP 400 missing_version. This shim adds the spec's own default for the rest
// of the API (2025-09-03) to any request to Notion that has no Notion-Version,
// and leaves a header the server did set (the markdown tools' 2026-03-11)
// untouched. Setting the version through OPENAPI_MCP_HEADERS instead would pin
// ONE version for every tool and break either the markdown tools or the rest.
//
// It never reads or logs the Authorization header or any other header value.
'use strict';

const http = require('http');
const https = require('https');

const DEFAULT_VERSION = '2025-09-03';

// NOTION_VERSION_SHIM_EXTRA_HOST is a test seam: self-test.sh points it at a
// local listener. It is never set in production.
function targetHosts() {
  const hosts = new Set(['api.notion.com']);
  if (process.env.NOTION_VERSION_SHIM_EXTRA_HOST) hosts.add(process.env.NOTION_VERSION_SHIM_EXTRA_HOST);
  return hosts;
}

function hostOf(args) {
  for (const a of args) {
    if (typeof a === 'string') {
      try { return new URL(a).hostname; } catch (_) { /* not a URL */ }
    } else if (a instanceof URL) {
      return a.hostname;
    } else if (a && typeof a === 'object') {
      const h = a.hostname || a.host;
      if (h) return String(h).replace(/:\d+$/, '');
    }
  }
  return null;
}

// Returns args with Notion-Version added to the options object when the request
// targets Notion and carries none. Pure: never mutates its input.
function withDefaultVersion(args, hosts = targetHosts()) {
  const host = hostOf(args);
  if (!host || !hosts.has(host)) return args;
  const i = args.findIndex((a) => a && typeof a === 'object' && !(a instanceof URL));
  if (i === -1) return args; // (url[, cb]) form: no options to carry a header
  const headers = args[i].headers;
  if (Array.isArray(headers)) return args;
  const h = headers || {};
  if (Object.keys(h).some((k) => k.toLowerCase() === 'notion-version')) return args;
  const out = args.slice();
  out[i] = Object.assign({}, args[i], { headers: Object.assign({}, h, { 'Notion-Version': DEFAULT_VERSION }) });
  return out;
}

function install(mod) {
  for (const name of ['request', 'get']) {
    const orig = mod[name];
    mod[name] = function (...args) { return orig.apply(this, withDefaultVersion(args)); };
  }
}

install(http);
install(https);

module.exports = { withDefaultVersion, DEFAULT_VERSION };
