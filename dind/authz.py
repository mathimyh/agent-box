"""Docker authorization plugin for the agent-box dind sidecar.

The sidecar runs privileged. This plugin stops the agent from passing that
privilege on: it refuses containers that ask for host access (privileged,
added capabilities, devices, bind mounts, host namespaces) and the endpoints
that can grant it another way (plugins, builds, swarm). Everything else is
allowed. Any request that cannot be parsed is refused.

Protocol: https://docs.docker.com/engine/extend/plugins_authorization/
"""

import base64
import json
import os
import re
import socketserver
from http.server import BaseHTTPRequestHandler

SOCKET = '/run/docker/plugins/agent-box-authz.sock'

DENIED_PREFIXES = (
    '/plugins', '/build', '/session', '/swarm', '/services', '/nodes',
    '/secrets', '/configs', '/tasks',
)
HOST_MODES = ('PidMode', 'NetworkMode', 'IpcMode', 'UTSMode', 'UsernsMode', 'CgroupnsMode')


def check_container(body):
    host = body.get('HostConfig') or {}
    if host.get('Privileged'):
        return 'privileged containers are not allowed'
    for key in ('CapAdd', 'Devices', 'DeviceRequests', 'DeviceCgroupRules', 'Sysctls'):
        if host.get(key):
            return f'HostConfig.{key} is not allowed'
    # "-v name:/path" also arrives in Binds. Only a path source is a host mount.
    for bind in host.get('Binds') or []:
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', bind.split(':', 1)[0]):
            return f'bind mount {bind} is not allowed'
    for key in HOST_MODES:
        if host.get(key) == 'host':
            return f'HostConfig.{key}=host is not allowed'
    if host.get('CgroupParent') or host.get('Runtime') not in (None, '', 'runc'):
        return 'custom cgroup parent or runtime is not allowed'
    for opt in host.get('SecurityOpt') or []:
        if not opt.startswith('no-new-privileges'):
            return f'SecurityOpt {opt} is not allowed'
    for mount in host.get('Mounts') or []:
        if mount.get('Type') not in ('volume', 'tmpfs'):
            return f'{mount.get("Type")} mounts are not allowed'
        if (mount.get('VolumeOptions') or {}).get('DriverConfig'):
            return 'volume driver options are not allowed'
    return None


def check(method, uri, body):
    path = re.sub(r'^/v[0-9.]+', '', uri.split('?', 1)[0])
    if path.startswith(DENIED_PREFIXES):
        return f'{path} is not allowed'
    if method != 'POST':
        return None
    if path == '/containers/create':
        return check_container(body) if body is not None else 'request body missing'
    if re.fullmatch(r'/containers/[^/]+/exec', path):
        if body is None:
            return 'request body missing'
        return 'privileged exec is not allowed' if body.get('Privileged') else None
    if path == '/volumes/create':
        if body is None:
            return 'request body missing'
        if body.get('DriverOpts') or body.get('Driver') not in (None, '', 'local'):
            return 'volume driver options are not allowed'
    if path == '/networks/create':
        if body is None:
            return 'request body missing'
        if body.get('Driver') not in (None, '', 'bridge') or body.get('Options'):
            return 'only plain bridge networks are allowed'
    return None


def decide(request):
    try:
        raw = request.get('RequestBody')
        body = json.loads(base64.b64decode(raw)) if raw else None
        reason = check(request['RequestMethod'], request['RequestUri'], body)
    except Exception as error:  # Fail closed.
        reason = f'agent-box-authz could not parse the request: {error}'
    if reason:
        return {'Allow': False, 'Msg': f'agent-box: {reason}'}
    return {'Allow': True}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        request = json.loads(self.rfile.read(length) or b'{}')
        if self.path == '/Plugin.Activate':
            reply = {'Implements': ['authz']}
        elif self.path == '/AuthZPlugin.AuthZReq':
            reply = decide(request)
        else:
            reply = {'Allow': True}
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/vnd.docker.plugins.v1+json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def address_string(self):
        return 'dockerd'


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


if __name__ == '__main__':
    os.makedirs(os.path.dirname(SOCKET), exist_ok=True)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    Server(SOCKET, Handler).serve_forever()
