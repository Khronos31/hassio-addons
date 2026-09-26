// Ingress は /api/hassio_ingress/<token> の下で開く。
// denpa の画面リンクは /guide のように根から書いてあるので、接頭辞を足す。
// 画面部品の ./_app は、URL の末尾に / が無いとトークンを消して解決される。
const upstream = "http://127.0.0.1:3000";
const upstreamWs = "ws://127.0.0.1:3000";

function upgrading(request) {
    const upgrade = request.headers.get("upgrade");
    const connection = request.headers.get("connection") || "";
    return upgrade?.toLowerCase() === "websocket" && connection.toLowerCase().includes("upgrade");
}

function hook(prefix) {
    return `
(function(){
  var p=${JSON.stringify(prefix)};
  function rewrite(v){
    if (typeof v!=="string") return v;
    if (v.charAt(0)==="/" && v.indexOf(p)!==0) return p+v;
    if (v.indexOf("./_app/")===0) return p+"/_app/"+v.slice(7);
    try {
      var u=new URL(v, location.href);
      var page=new URL(location.href);
      var proto=u.protocol;
      var same=u.host===page.host && (proto==="http:"||proto==="https:"||proto==="ws:"||proto==="wss:");
      if (same && u.pathname.indexOf(p)!==0) u.pathname=p+u.pathname;
      if (same) return u.toString();
    } catch (e) {}
    return v;
  }
  function text(v){
    if (typeof v==="string") return v;
    if (v && typeof v.href==="string") return v.href;
    return null;
  }
  // goto('/watch/1') は new URL('/watch/1', base) になる。
  // 先頭の / は base の Ingress 接頭辞を消すので、ここで付け直す。
  var NativeURL=URL;
  function IngressURL(url, base){
    var u=base===undefined?new NativeURL(url):new NativeURL(url, base);
    try {
      var page=new NativeURL(location.href);
      var proto=u.protocol;
      var same=u.host===page.host && (proto==="http:"||proto==="https:"||proto==="ws:"||proto==="wss:");
      if (same && u.pathname.indexOf(p)!==0) u.pathname=p+u.pathname;
    } catch (e) {}
    return u;
  }
  IngressURL.prototype=NativeURL.prototype;
  IngressURL.createObjectURL=NativeURL.createObjectURL.bind(NativeURL);
  IngressURL.revokeObjectURL=NativeURL.revokeObjectURL.bind(NativeURL);
  if (NativeURL.canParse) IngressURL.canParse=NativeURL.canParse.bind(NativeURL);
  if (NativeURL.parse) IngressURL.parse=function(url, base){ return new IngressURL(url, base); };
  window.URL=IngressURL;
  var of=window.fetch;
  window.fetch=function(input, init){
    if (typeof input==="string") input=rewrite(input);
    else if (typeof Request!=="undefined" && input instanceof Request) {
      try {
        var u=new URL(input.url, location.href);
        if (u.origin===location.origin) {
          var next=rewrite(u.pathname)+u.search+u.hash;
          if (next!==u.pathname+u.search+u.hash) input=new Request(next, input);
        }
      } catch (e) {}
    }
    return of.call(this, input, init);
  };
  var xo=XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open=function(method, url){
    arguments[1]=rewrite(url);
    return xo.apply(this, arguments);
  };
  var WS=window.WebSocket;
  window.WebSocket=function(url, proto){
    return new WS(rewrite(String(url)), proto);
  };
  var ES=window.EventSource;
  window.EventSource=function(url, init){
    return new ES(rewrite(String(url)), init);
  };
  // 録画の行は goto('/watch/番号')。失敗すると location.href に接頭辞の無い
  // URL を入れて、Home Assistant 本体の 404 になる。
  try {
    var assign=Location.prototype.assign;
    Location.prototype.assign=function(v){ return assign.call(this, rewrite(String(v))); };
    var replace=Location.prototype.replace;
    Location.prototype.replace=function(v){ return replace.call(this, rewrite(String(v))); };
    var href=Object.getOwnPropertyDescriptor(Location.prototype, "href");
    if (href && href.set && href.get) {
      Object.defineProperty(Location.prototype, "href", {
        configurable: true,
        enumerable: href.enumerable,
        get: function(){ return href.get.call(this); },
        set: function(v){ href.set.call(this, rewrite(String(v))); }
      });
    }
  } catch (e) {}
  function hookProp(obj, prop){
    if (!obj) return;
    var d=Object.getOwnPropertyDescriptor(obj, prop);
    if(!d || !d.set || !d.get) return;
    Object.defineProperty(obj, prop, {
      configurable: true,
      enumerable: d.enumerable,
      get: function(){ return d.get.call(this); },
      set: function(v){ d.set.call(this, rewrite(v)); }
    });
  }
  try { hookProp(HTMLAnchorElement.prototype, "href"); } catch (e) {}
  try { hookProp(HTMLFormElement.prototype, "action"); } catch (e) {}
  try { hookProp(HTMLScriptElement.prototype, "src"); } catch (e) {}
  try { hookProp(HTMLLinkElement.prototype, "href"); } catch (e) {}
  try { hookProp(HTMLImageElement.prototype, "src"); } catch (e) {}
  try { hookProp(HTMLMediaElement.prototype, "src"); } catch (e) {}
  try { hookProp(HTMLSourceElement.prototype, "src"); } catch (e) {}
  var sa=Element.prototype.setAttribute;
  Element.prototype.setAttribute=function(name, value){
    if (name==="href" || name==="src" || name==="action") value=rewrite(value);
    return sa.call(this, name, value);
  };
  function wrapHistory(name){
    var orig=history[name];
    history[name]=function(state, title, url){
      var s=text(url);
      if (s!==null) url=rewrite(s);
      return orig.call(this, state, title, url);
    };
  }
  wrapHistory("pushState");
  wrapHistory("replaceState");
})();`;
}

function rewriteHtml(html, prefix) {
    let out = html.replace(/(href|src|action)=("|\')\//g, `$1=$2${prefix}/`);
    out = out.replace(/(href|src)=("|\')\.\/_app\//g, `$1=$2${prefix}/_app/`);
    out = out.replace(/import\("\.\/_app\//g, `import("${prefix}/_app/`);
    const head = `<head><script>${hook(prefix)}</script>`;
    return out.replace(/<head>/i, head);
}

function rewriteLink(value, prefix) {
    return value.replace(/<\.\/_app\//g, `<${prefix}/_app/`);
}

Bun.serve({
    port: 3002,
    hostname: "0.0.0.0",
    idleTimeout: 0,
    fetch(request, server) {
        const url = new URL(request.url);
        if (upgrading(request)) {
            const ok = server.upgrade(request, { data: { path: url.pathname + url.search } });
            return ok ? undefined : new Response("upgrade failed", { status: 400 });
        }
        return proxyHttp(request);
    },
    websocket: {
        open(ws) {
            const upstreamSocket = new WebSocket(upstreamWs + ws.data.path);
            upstreamSocket.binaryType = "arraybuffer";
            const pending = [];
            ws.data.upstream = upstreamSocket;
            ws.data.pending = pending;
            upstreamSocket.onopen = () => {
                for (const message of pending) upstreamSocket.send(message);
                ws.data.pending = null;
            };
            upstreamSocket.onmessage = (event) => {
                if (ws.readyState === WebSocket.OPEN) ws.send(event.data);
            };
            upstreamSocket.onclose = () => {
                try { ws.close(); } catch { /* already closed */ }
            };
            upstreamSocket.onerror = () => {
                try { ws.close(); } catch { /* already closed */ }
            };
        },
        message(ws, message) {
            const upstreamSocket = ws.data.upstream;
            if (!upstreamSocket || upstreamSocket.readyState !== WebSocket.OPEN) {
                ws.data.pending?.push(message);
                return;
            }
            upstreamSocket.send(message);
        },
        close(ws) {
            try { ws.data.upstream?.close(); } catch { /* already closed */ }
        },
    },
});

async function proxyHttp(request) {
        const url = new URL(request.url);
        const headers = new Headers(request.headers);
        headers.set("accept-encoding", "identity");
        const prefix = headers.get("x-ingress-path") || "";
        const response = await fetch(`${upstream}${url.pathname}${url.search}`, {
            method: request.method,
            headers,
            body: request.body,
            redirect: "manual",
        });
        const out = new Headers(response.headers);
        const location = out.get("location");
        if (prefix && location && location.startsWith("/") && !location.startsWith(prefix)) {
            out.set("location", prefix + location);
        }
        if (prefix && out.get("link")) {
            out.set("link", rewriteLink(out.get("link"), prefix));
        }
        const type = out.get("content-type") || "";
        if (prefix && type.includes("text/html")) {
            const html = rewriteHtml(await response.text(), prefix);
            out.delete("content-length");
            return new Response(html, { status: response.status, headers: out });
        }
        return new Response(response.body, { status: response.status, headers: out });
}