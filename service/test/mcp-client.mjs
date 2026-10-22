// A minimal MCP Streamable-HTTP client (JSON responses only), for the tests and
// as a reference for calling the service's /mcp endpoint without an SDK.
//
//   const c = new McpClient('http://127.0.0.1:8080/mcp');
//   await c.initialize();                       // the server assigns c.sessionId
//   const text = await c.tool('goto', { url }); // throws on a tool error
//   await c.close();                            // DELETE: ends the session

export class McpError extends Error {}

export class McpClient {
    constructor(url, { sessionId = null, headers = {} } = {}) {
        this.url = url;
        this.sessionId = sessionId;
        this.headers = headers;
        this.nextId = 1;
    }

    async post(message) {
        const headers = { 'content-type': 'application/json', accept: 'application/json, text/event-stream', ...this.headers };
        if (this.sessionId) headers['mcp-session-id'] = this.sessionId;
        const r = await fetch(this.url, { method: 'POST', headers, body: JSON.stringify(message) });
        const sid = r.headers.get('mcp-session-id');
        if (sid) this.sessionId = sid;
        const text = await r.text();
        if (r.status === 202) return null;
        if (!r.ok) throw new McpError(`HTTP ${r.status}: ${text.slice(0, 300)}`);
        return JSON.parse(text);
    }

    async request(method, params = {}) {
        const res = await this.post({ jsonrpc: '2.0', id: this.nextId++, method, params });
        if (res.error) throw new McpError(`${method}: ${res.error.message}`);
        return res.result;
    }

    async initialize() {
        const result = await this.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'mcp-client.mjs', version: '1' } });
        await this.post({ jsonrpc: '2.0', method: 'notifications/initialized' });
        return result;
    }

    // The tool's text output; a result with isError throws (message = text).
    async tool(name, args = {}) {
        const result = await this.request('tools/call', { name, arguments: args });
        const text = (result.content ?? []).filter((c) => c.type === 'text').map((c) => c.text).join('\n');
        if (result.isError) throw new McpError(`${name}: ${text}`);
        return text;
    }

    async close() {
        if (!this.sessionId) return;
        const r = await fetch(this.url, { method: 'DELETE', headers: { 'mcp-session-id': this.sessionId, ...this.headers } });
        await r.arrayBuffer();
        return r.status;
    }
}
