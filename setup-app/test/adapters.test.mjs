import test from "node:test";
import assert from "node:assert/strict";
import { parseActiveSshSessions, parseSavedSshHosts, parseSshAliases } from "../src/adapters/system-checks.mjs";
import { generateRemoteInstallHandoff, generateSmartThingsHandoff } from "../src/handoff.mjs";
import { __testables as sshTestables } from "../src/adapters/ssh.mjs";
import { __testables as dockerTestables } from "../src/adapters/remote-docker.mjs";

test("parseSavedSshHosts extracts concrete saved hosts", () => {
  const hosts = parseSavedSshHosts(`
Host ubuntu-2204-agent-stack
  HostName 10.0.0.4
  User ubuntu
  Port 2202
Host *
  ForwardAgent no
Host bedjet-lab backup-host
  HostName 10.0.0.9
  ProxyJump jump-box
`);

  assert.deepEqual(parseSshAliases(`
Host ubuntu-2204-agent-stack
Host bedjet-lab backup-host
`), ["ubuntu-2204-agent-stack", "bedjet-lab", "backup-host"]);

  assert.equal(hosts.length, 3);
  assert.equal(hosts[0].label, "ubuntu-2204-agent-stack");
  assert.equal(hosts[0].host, "10.0.0.4");
  assert.equal(hosts[0].user, "ubuntu");
  assert.equal(hosts[0].port, "2202");
  assert.equal(hosts[1].tunnelHint, "ProxyJump jump-box");
});

test("parseActiveSshSessions extracts active ssh targets and tunnel hints", () => {
  const sessions = parseActiveSshSessions(`UID PID PPID C STIME TTY TIME CMD
devuser 11012 11004 0 17:06 pts/7 00:00:00 ssh -o ProxyCommand=ssh -p 22 -W %h:%p admin@100.64.0.10 -p 22 ubuntu@100.64.0.20 bash -lc 'exec bash -l'
devuser 13934 653 0 17:43 ? 00:00:00 ssh -N -L 2223:127.0.0.1:2222 -o ExitOnForwardFailure=yes admin@100.64.0.10
`);

  assert.equal(sessions.length, 2);
  assert.equal(sessions[0].target, "ubuntu@100.64.0.20");
  assert.equal(sessions[0].port, "22");
  assert.match(sessions[0].tunnelHint, /ProxyCommand|Via/);
  assert.equal(sessions[1].target, "admin@100.64.0.10");
  assert.equal(sessions[1].tunnelHint, "Local forward 2223:127.0.0.1:2222");
});

test("parseSshConfigOutput extracts resolved fields", () => {
  const parsed = sshTestables.parseSshConfigOutput(`
hostname 10.0.0.4
user ubuntu
port 22
`);

  assert.equal(parsed.hostname, "10.0.0.4");
  assert.equal(parsed.user, "ubuntu");
  assert.equal(parsed.port, "22");
});

test("docker action planning marks required next actions", () => {
  const facts = dockerTestables.factsFromRemoteOutput({
    resolved: { hostname: "10.0.0.4", user: "ubuntu", port: "22" },
    stdout: `
os_id=ubuntu
os_version=22.04
has_apt=1
has_systemctl=1
has_passwordless_sudo=1
has_docker=0
daemon_usable=0
compose_available=0
`,
    stderr: "",
    completedActionIds: ["install-packages"]
  });

  assert.equal(facts.ok, true);
  assert.equal(facts.healthy, false);
  assert.equal(facts.reason, "Docker is not installed on the selected host.");
  assert.equal(facts.actions[0].id, "install-packages");
  assert.equal(facts.actions[0].done, true);
  assert.ok(facts.actions.some((action) => action.id === "enable-service"));
});

test("handoff generators include key commands", () => {
  const remote = generateRemoteInstallHandoff({
    target: "ubuntu-2204-agent-stack",
    installPath: "~/apps/bedjet-smartthings-bridge",
    bridgeUrl: "http://10.0.0.4:8787"
  });
  const smartthings = generateSmartThingsHandoff({
    channelId: "channel-123",
    hubId: "hub-456",
    smartThingsRoot: "/mnt/d/Dev/bedjet-smartthings-bridge/smartthings-edge"
  });

  assert.match(remote, /install-bridge-remote\.sh/);
  assert.match(remote, /curl -fsS http:\/\/127\.0\.0\.1:8787\/healthz/);
  assert.match(smartthings, /smartthings edge:drivers:package/);
  assert.match(smartthings, /--channel channel-123 --hub hub-456/);
});
