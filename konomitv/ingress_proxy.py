#!/usr/bin/env python3
"""Ingress 用の HTTP 中継。

KonomiTV の本体は 127.0.0.77:7010 で HTTP を話す。外向けの 7000 は
*.local.konomi.tv 用の HTTPS なので、Ingress からは届かない。
この中継は 0.0.0.0:7011 で受け、HTML の根からのパスに
X-Ingress-Path を足してから返す。
"""

import asyncio
import pathlib
import sys

UPSTREAM = ("127.0.0.77", 7010)
LISTEN = ("0.0.0.0", 7011)

API_OLD = 'Ge(yt,"api_base_url",`${self.location.protocol}//${self.location.host}/api`)'
API_NEW = (
    'Ge(yt,"api_base_url",`${self.location.protocol}//${self.location.host}'
    '${(self.location.pathname.match(/^\\/api\\/hassio_ingress\\/[^/]+/)||[""])[0]}/api`)'
)
ROUTER_OLD = 'history:gk("/")'
ROUTER_NEW = 'history:gk((location.pathname.match(/^\\/api\\/hassio_ingress\\/[^/]+/)||["/"])[0])'
ASSET_OLD = 'AO=function(e){return"/"+e}'
ASSET_NEW = (
    'AO=function(e){const p=(location.pathname.match(/^\\/api\\/hassio_ingress\\/[^/]+/)||[""])[0];'
    'return p+"/"+e}'
)
HOOK = """<script>
(function(){
  // HA を http://192.168.x.x で開くと安全なコンテキストにならない。
  // crypto.randomUUID が無く、録画再生のセッション ID 生成で初期化が落ちる。
  if (typeof crypto.randomUUID !== "function") {
    crypto.randomUUID = function() {
      var bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      bytes[6] = (bytes[6] & 15) | 64;
      bytes[8] = (bytes[8] & 63) | 128;
      var hex = Array.from(bytes, function(value) {
        return value.toString(16).padStart(2, "0");
      }).join("");
      return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" +
        hex.slice(12, 16) + "-" + hex.slice(16, 20) + "-" + hex.slice(20);
    };
  }
  var m=location.pathname.match(/^\\/api\\/hassio_ingress\\/[^/]+/);
  if(!m) return;
  var p=m[0];
  function rewrite(v){
    return typeof v==="string" && v.charAt(0)==="/" && v.indexOf(p)!==0 ? p+v : v;
  }
  function hook(proto, prop){
    var d=Object.getOwnPropertyDescriptor(proto, prop);
    if(!d || !d.set || !d.get) return;
    Object.defineProperty(proto, prop, {
      configurable: true,
      enumerable: d.enumerable,
      get: function(){ return d.get.call(this); },
      set: function(v){ d.set.call(this, rewrite(v)); }
    });
  }
  hook(HTMLLinkElement.prototype, "href");
  hook(HTMLScriptElement.prototype, "src");
  hook(HTMLImageElement.prototype, "src");
})();
</script>
"""


def patch_assets(dist: pathlib.Path) -> None:
    patched = 0
    for file in sorted(dist.glob("assets/*.js")):
        text = file.read_text(encoding="utf-8")
        new = text
        if API_OLD in new:
            new = new.replace(API_OLD, API_NEW, 1)
        if ROUTER_OLD in new:
            new = new.replace(ROUTER_OLD, ROUTER_NEW, 1)
        if ASSET_OLD in new:
            new = new.replace(ASSET_OLD, ASSET_NEW, 1)
        if new == text:
            continue
        file.write_text(new, encoding="utf-8")
        patched += 1
        print(f"Ingress 向けに書き換えました: {file}", flush=True)
    if patched:
        return
    already = any("hassio_ingress" in file.read_text(encoding="utf-8") for file in dist.glob("assets/*.js"))
    if already:
        print("Ingress 向けの書き換え済みです", flush=True)
        return
    raise SystemExit(f"書き換え対象が {dist}/assets にありません")


def rewrite_html(body: bytes, prefix: str) -> bytes:
    prefix = prefix.rstrip("/")
    if not prefix:
        return body
    text = body.decode("utf-8")
    if "<head>" in text and "hassio_ingress" not in text:
        text = text.replace("<head>", "<head>" + HOOK, 1)
    for attr in ("href", "src"):
        text = text.replace(f'{attr}="/', f'{attr}="{prefix}/')
        text = text.replace(f"{attr}='/", f"{attr}='{prefix}/")
    text = text.replace("url('/", f"url('{prefix}/")
    text = text.replace('url("/', f'url("{prefix}/')
    # ファイル名は同じまま中身だけ変えたので、古い JS を使わせない。
    text = text.replace('.js"', '.js?v=3"')
    text = text.replace('.css"', '.css?v=3"')
    return text.encode("utf-8")


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except ConnectionError:
            pass


async def read_headers(reader: asyncio.StreamReader) -> bytes:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = await reader.read(65536)
        if not chunk:
            break
        data += chunk
        if len(data) > 1024 * 1024:
            break
    return data


def header_value(head: bytes, name: str) -> str:
    key = name.lower().encode()
    for line in head.split(b"\r\n")[1:]:
        if line.lower().startswith(key + b":"):
            return line.split(b":", 1)[1].strip().decode("latin1")
    return ""


async def handle(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter) -> None:
    try:
        request = await read_headers(client_reader)
        if not request:
            client_writer.close()
            return
        head, _, rest = request.partition(b"\r\n\r\n")
        prefix = header_value(head, "x-ingress-path")
        length_text = header_value(head, "content-length")
        body = rest
        if length_text.isdigit():
            need = int(length_text)
            while len(body) < need:
                chunk = await client_reader.read(need - len(body))
                if not chunk:
                    break
                body += chunk
            body = body[:need]
        # 上流は自分の Host で受ける。ブラウザの Host を渡すと HTTPS 名へ飛ばす。
        lines = head.split(b"\r\n")
        rewritten = [lines[0]]
        for line in lines[1:]:
            if line.lower().startswith(b"host:"):
                rewritten.append(b"Host: 127.0.0.77:7010")
            else:
                rewritten.append(line)
        upstream_reader, upstream_writer = await asyncio.open_connection(*UPSTREAM)
        upstream_writer.write(b"\r\n".join(rewritten) + b"\r\n\r\n" + body)
        await upstream_writer.drain()
        response = await read_headers(upstream_reader)
        resp_head, _, resp_rest = response.partition(b"\r\n\r\n")
        content_type = header_value(resp_head, "content-type")
        length_text = header_value(resp_head, "content-length")
        if prefix and content_type.startswith("text/html") and length_text.isdigit():
            length = int(length_text)
            body = resp_rest
            while len(body) < length:
                body += await upstream_reader.read(length - len(body))
            body = rewrite_html(body[:length], prefix)
            new_head = []
            for line in resp_head.split(b"\r\n"):
                lower = line.lower()
                if lower.startswith(b"content-length:"):
                    new_head.append(f"Content-Length: {len(body)}".encode())
                elif lower.startswith((b"etag:", b"last-modified:", b"cache-control:")):
                    continue
                else:
                    new_head.append(line)
            new_head.append(b"Cache-Control: no-cache")
            client_writer.write(b"\r\n".join(new_head) + b"\r\n\r\n" + body)
            await client_writer.drain()
            client_writer.close()
            upstream_writer.close()
            return
        client_writer.write(response)
        await client_writer.drain()
        await asyncio.gather(
            pipe(client_reader, upstream_writer),
            pipe(upstream_reader, client_writer),
        )
    except (ConnectionError, OSError, asyncio.TimeoutError):
        try:
            client_writer.close()
        except ConnectionError:
            pass


async def main() -> None:
    server = await asyncio.start_server(handle, *LISTEN)
    print("Ingress proxy listening on 7011", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--patch-assets":
        patch_assets(pathlib.Path(sys.argv[2]))
    else:
        asyncio.run(main())
