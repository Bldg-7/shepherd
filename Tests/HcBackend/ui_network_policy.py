"""Private UI socket scopes plus, optionally, one owned loopback SSH port."""
import json

def policy(core_root, remote_root=None, port=None):
    if (remote_root is None) != (port is None):raise ValueError('remote scope and port must be supplied together')
    rules='(version 1)\n(allow default)\n(deny network*)\n(allow network* (subpath '+json.dumps(str(core_root))+'))\n'
    if port is not None:
        if not isinstance(port,int) or isinstance(port,bool) or not 1<=port<=65535:raise ValueError('invalid owned port')
        # Apple's SB network address grammar accepts localhost or *, not a
        # numeric host here. This remains one port; never localhost:*.
        rules+='(allow network* (subpath '+json.dumps(str(remote_root))+'))\n'
        rules+='(allow network-outbound (remote ip "localhost:'+str(port)+'"))\n'
        rules+='(allow network-inbound (local ip "localhost:'+str(port)+'"))\n'
    return rules
