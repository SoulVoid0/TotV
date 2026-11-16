"""Host-side tests (no game, no compositor): QT_QPA_PLATFORM=offscreen python3 -m unittest"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "host" / "lib"))
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

TMP = tempfile.mkdtemp()
os.environ["VOTV_OS_RUNTIME_LINUX"] = str(Path(TMP) / "rt")
os.environ["XDG_CONFIG_HOME"] = str(Path(TMP) / "cfg")
os.environ["VOTV_ROOT"] = str(Path(TMP) / "VotV")
os.environ["VOTV_OS_SYSCFG_LINUX"] = str(Path(TMP) / "none.json")

from votvos import config, ipc, paths  # noqa: E402


class IpcTest(unittest.TestCase):
    def setUp(self):
        ipc.reset_session()
        self.link = ipc.GameLink()

    def test_commands_are_json_lines(self):
        req = self.link.send("relay_click", id="r/0/2")
        line = (paths.runtime_dir() / "host-commands.jsonl").read_text().splitlines()[-1]
        self.assertEqual(json.loads(line), {"type": "relay_click", "req": req, "id": "r/0/2"})

    def test_events_partial_lines_wait(self):
        ev = paths.runtime_dir() / "game-events.jsonl"
        with open(ev, "a") as f:
            f.write('{"type":"hello"}\n{"type":"pc_ac')
        self.assertEqual([m["type"] for m in self.link.poll()], ["hello"])
        with open(ev, "a") as f:
            f.write('tive","active":true}\n')
        self.assertEqual(list(self.link.poll()), [{"type": "pc_active", "active": True}])

    def test_truncated_log_restarts(self):
        ev = paths.runtime_dir() / "game-events.jsonl"
        ev.write_text('{"type":"a"}\n')
        list(self.link.poll())
        ev.write_text('{"c":1}\n')         # shorter: the file was truncated
        with open(ev, "a") as f:
            f.write('{"type":"c"}\n')
        list(self.link.poll())
        ev.write_text("")
        with open(ev, "a") as f:
            f.write('{"type":"c"}\n')
        self.assertEqual([m["type"] for m in self.link.poll()], ["c"])


class ConfigTest(unittest.TestCase):
    def test_user_settings_override_defaults(self):
        config.set_user("pc.camera.pitch", 2.5)
        eff = config.effective()
        self.assertEqual(eff["pc"]["camera"]["pitch"], 2.5)
        self.assertEqual(eff["pc"]["camera"]["yaw"], 0.0)
        self.assertTrue(eff["saves"]["enabled"])
        self.assertEqual(eff["home"]["base_mode"], 1)

    def test_user_conf_parsing(self):
        p = Path(TMP) / "user.conf"
        p.write_text('# x\nUSERNAME=alice\nSAVE_NAME="Alice Two"\n')
        self.assertEqual(paths.read_user_conf(p), {"USERNAME": "alice", "SAVE_NAME": "Alice Two"})

    def test_windows_paths(self):
        self.assertEqual(paths.to_windows("/run/user/1000/votv-os"), "C:\\run\\user\\1000\\votv-os")


class EngineIniTest(unittest.TestCase):
    def test_idempotent_and_keeps_user_lines(self):
        ini = Path(TMP) / "Engine.ini"
        ini.write_text("[Core.Log]\nLogFoo=Verbose\n")
        tool = HERE.parent / "host" / "bin" / "votv-os-engine-ini"
        for _ in range(3):
            subprocess.run([sys.executable, str(tool), str(ini)], check=True)
        text = ini.read_text()
        self.assertIn("LogFoo=Verbose", text)
        self.assertEqual(text.count("; >>> TotV OS"), 1)
        self.assertIn("gc.MultithreadedDestructionEnabled=1", text)


class QtTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from PyQt6.QtWidgets import QApplication
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        ipc.reset_session()

    def test_mirror_view_click_sends_command(self):
        from PyQt6.QtCore import QPoint, Qt
        from PyQt6.QtTest import QTest
        from votvos.mirrorview import MirrorView
        link = ipc.GameLink()
        link.write("laptop-ui.json", {"seq": 1, "width": 800, "height": 600, "items": [
            {"id": "r/0", "kind": "text", "x": 0, "y": 0, "w": 800, "h": 40, "text": "Email"},
            {"id": "r/1", "kind": "button", "name": "Button_tab_store", "x": 400, "y": 300, "w": 100, "h": 50},
        ]})
        view = MirrorView(link, "laptop-ui.json", "relay", allow_tap=True)
        view.resize(800, 600)
        view.refresh()
        view.grab()   # paints
        QTest.mouseClick(view, Qt.MouseButton.LeftButton, pos=QPoint(450, 325))
        QTest.mouseClick(view, Qt.MouseButton.LeftButton, pos=QPoint(100, 500))
        lines = [json.loads(x) for x in (paths.runtime_dir() / "host-commands.jsonl").read_text().splitlines()]
        self.assertEqual(lines[0]["type"], "relay_click")
        self.assertEqual(lines[0]["id"], "r/1")
        self.assertEqual(lines[1]["type"], "relay_tap")
        self.assertAlmostEqual(lines[1]["u"], 0.125, places=2)

    def test_bridge_shows_pc_after_delay_and_leaves(self):
        from PyQt6.QtCore import QCoreApplication
        from PyQt6.QtTest import QTest
        from votvos.bridge import Bridge
        b = Bridge(self.app)
        self.assertTrue((paths.runtime_dir() / "screens.json").exists())
        with open(paths.runtime_dir() / "game-events.jsonl", "a") as f:
            f.write('{"type":"pc_active","active":true,"delay":0.05}\n')
        b.poll_events()
        self.assertFalse(b.pc_visible)
        QTest.qWait(150)
        QCoreApplication.processEvents()
        self.assertTrue(b.pc_visible)
        self.assertTrue(b.window_state()["pc"]["visible"])
        b.leave_pc()
        self.assertFalse(b.pc_visible)
        cmds = [json.loads(x)["type"] for x in (paths.runtime_dir() / "host-commands.jsonl").read_text().splitlines()]
        self.assertIn("overlay_shown", cmds)
        self.assertEqual(cmds[-1], "leave_pc")
        b._events.stop()
        b._slow.stop()

    def test_bridge_follows_login_and_logout(self):
        from votvos.bridge import Bridge
        from votvos.saves import Registry
        rt = paths.runtime_dir()
        (rt / "session.json").unlink(missing_ok=True)
        (rt / "target.json").unlink(missing_ok=True)
        b = Bridge(self.app)
        reg = Registry(runtime=rt)
        self.assertEqual(reg.running()["name"], "default")
        self.assertEqual(reg.running()["mode"], "home")
        (rt / "session.json").write_text('{"user": "alice"}')
        b.follow_session()
        self.assertEqual(reg.running()["name"], "alice")
        self.assertEqual(reg.get("alice")["owner"], "alice")
        (rt / "session.json").unlink()
        b.follow_session()
        self.assertEqual(reg.running()["name"], "default")
        b._events.stop()
        b._slow.stop()


class SavesTest(unittest.TestCase):
    def test_registry(self):
        from votvos.saves import Registry, SaveError
        d = Path(tempfile.mkdtemp())
        reg = Registry(root=d / "saves", runtime=d)
        reg.ensure_builtin("bob")
        n = reg.create("bob", "My Station", "sandbox")
        self.assertEqual(n, "bob-My Station")
        self.assertEqual(reg.create("bob", "My Station", "story"), "bob-My Station 2")
        self.assertNotIn(n, reg.for_user("eve"))
        self.assertIn("default", reg.for_user("eve"))
        with self.assertRaises(SaveError):
            reg.delete("eve", n)
        with self.assertRaises(SaveError):
            reg.delete("bob", "bob")          # the user's own save stays
        with self.assertRaises(SaveError):
            reg.rename("bob", "default", "x")  # the shared one too
        t = reg.load(n, "bob")
        self.assertEqual((t["name"], t["mode"]), (n, "sandbox"))
        with self.assertRaises(SaveError):
            reg.delete("bob", n, running=n)
        (d / "saves" / "prefixes.json").write_text('{"4": "sbx_"}')
        (d / "saves" / "games").mkdir(parents=True, exist_ok=True)
        (d / "saves" / "games" / f"sbx_{n}.sav").write_bytes(b"GVAS")
        c = reg.duplicate("bob", n, "Copy")
        self.assertTrue((d / "saves" / "games" / f"sbx_{c}.sav").exists())
        reg.delete("bob", n)
        self.assertNotIn(n, reg.all())
        self.assertFalse((d / "saves" / "games" / f"sbx_{n}.sav").exists())


class ModsTest(unittest.TestCase):
    def test_install_routes_and_manifest(self):
        import io
        import zipfile
        from votvos import mods
        prof = Path(tempfile.mkdtemp())
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("manifest.json", "{}")
            z.writestr("CoolMod/Scripts/main.lua", "print(1)")
            z.writestr("CoolMod/enabled.txt", "")
            z.writestr("pak/Cool_P.pak", "PAK")
            z.writestr("cfg/cool.ini", "x=1")
        payload = buf.getvalue()
        index = [
            {"full_name": "Ann-Cool", "owner": "Ann", "name": "Cool", "versions": [
                {"version_number": "1.2.3", "dependencies": ["Thunderstore-unreal_shimloader-1.1.7", "Bo-Lib-0.1.0"],
                 "download_url": "x"}]},
            {"full_name": "Bo-Lib", "owner": "Bo", "name": "Lib", "versions": [
                {"version_number": "0.1.0", "dependencies": [], "download_url": "y"}]},
        ]
        mods.download = lambda pkg, ver: payload
        done = mods.install(index, "Ann-Cool", prof)
        self.assertEqual(done, ["Bo-Lib-0.1.0", "Ann-Cool-1.2.3"])
        self.assertTrue((prof / "shimloader/mod/Ann-Cool/CoolMod/Scripts/main.lua").exists())
        self.assertTrue((prof / "shimloader/pak/Ann-Cool/Cool_P.pak").exists())
        self.assertTrue((prof / "shimloader/cfg/cool.ini").exists())
        inst = mods.installed(prof)
        self.assertEqual(inst["Ann-Cool"]["versionNumber"], {"major": 1, "minor": 2, "patch": 3})
        self.assertEqual(mods.plan(index, "Ann-Cool", prof), [])
        self.assertIn("Ann-Cool-1.2.3", mods.pending(prof)["installed"])
        with self.assertRaises(mods.ModError):
            mods.uninstall("Bo-Lib", prof)   # Ann-Cool needs it
        mods.uninstall("Ann-Cool", prof)
        self.assertFalse((prof / "shimloader/mod/Ann-Cool").exists())
        self.assertNotIn("Ann-Cool", mods.installed(prof))
        with self.assertRaises(mods.ModError):
            mods.uninstall("TotV-TotVOS", prof)


if __name__ == "__main__":
    unittest.main()
