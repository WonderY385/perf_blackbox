@tool
extends SceneTree
## F2 MCP server 的传输层：本机 TCP + 按行分隔的 JSON-RPC 2.0。
##
## 为什么不用 stdio（三条都是实测出来的）：
## 1. Godot 启动会把版本横幅 print 到 stdout，严格解析 JSON 的客户端会当场报错；
## 2. `--quiet` 能压掉横幅，但**连 `print()` 一起压掉** —— 协议响应根本发不出去；
## 3. 本项目已装了其它带 autoload 的插件（godot_ai 的 game_helper 会往 stdout 打日志）。
## 所以走本机 TCP：这也正是 Godot 生态里 MCP 桥（如 Render Lens 的 127.0.0.1:43788）的常见做法。
##
## 启动：
##   godot --headless --quiet --path <项目> --script res://addons/perf_blackbox/tools/bb_mcp.gd -- --port=43790
##
## 客户端：任何「一行一条 JSON-RPC」的 MCP 客户端，或一个 stdio↔TCP 的中继。
## 协议本身是标准 MCP：initialize / notifications/* / ping / tools/list / tools/call。

const DEFAULT_PORT := 43790
const DEFAULT_HOST := "127.0.0.1"
const MAX_BUFFER := 8 << 20

var _server := TCPServer.new()
var _conns: Array[Dictionary] = []
var _port := DEFAULT_PORT
var _host := DEFAULT_HOST


func _initialize() -> void:
	_port = _arg_int("port", DEFAULT_PORT)
	_host = _arg_str("host", DEFAULT_HOST)
	var err := _server.listen(_port, _host)
	if err != OK:
		printerr("[bb_mcp] 无法监听 %s:%d（err %d）" % [_host, _port, err])
		quit(1)
		return
	printerr("[bb_mcp] Perf Blackbox MCP server 监听 tcp://%s:%d（协议 %s）" % [_host, _port, BBMcpServer.PROTOCOL_VERSION])


func _process(_delta: float) -> bool:
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			continue
		_conns.append({"peer": peer, "buf": ""})
		printerr("[bb_mcp] 客户端接入（当前 %d 个连接）" % _conns.size())

	var alive: Array[Dictionary] = []
	for conn in _conns:
		var peer: StreamPeerTCP = conn["peer"]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			printerr("[bb_mcp] 客户端断开")
			continue
		var avail := peer.get_available_bytes()
		if avail > 0:
			var got: Array = peer.get_data(avail)
			var bytes: PackedByteArray = got[1]
			if not bytes.is_empty():
				var text := String(conn["buf"]) + bytes.get_string_from_utf8()
				if text.length() > MAX_BUFFER:
					printerr("[bb_mcp] 输入缓冲过大，丢弃")
					text = ""
				conn["buf"] = text
				_drain(conn)
		alive.append(conn)
	_conns = alive
	return false


func _drain(conn: Dictionary) -> void:
	var peer: StreamPeerTCP = conn["peer"]
	while true:
		var buf := String(conn["buf"])
		var nl := buf.find("\n")
		if nl < 0:
			conn["buf"] = buf
			return
		var line := buf.substr(0, nl).strip_edges()
		conn["buf"] = buf.substr(nl + 1)
		if line == "":
			continue
		var parsed = JSON.parse_string(line)
		if not (parsed is Dictionary):
			_send(peer, {"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "非法 JSON"}})
			continue
		var response: Dictionary = BBMcpServer.handle(parsed)
		if response.is_empty():
			continue  # notification：不回复
		_send(peer, response)


func _send(peer: StreamPeerTCP, payload: Dictionary) -> void:
	var text := JSON.stringify(payload) + "\n"
	peer.put_data(text.to_utf8_buffer())


func _arg_str(key: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % key):
			return a.substr(key.length() + 3)
	return fallback


func _arg_int(key: String, fallback: int) -> int:
	return int(_arg_str(key, str(fallback)))
