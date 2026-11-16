// TotV OS window placement (KWin 6 declarative script).
// Asks votv-os-bridge (org.totv.VotvOS.WindowState) ten times a second where each
// window belongs:
//   the game          fullscreen on the primary monitor
//   the PC            (fullscreen whenever the game is not running)
//                     the login screen (votv-login) while nobody is logged in, else the
//                     user's desktop (nested KWin running Plasma): over the game,
//                     fullscreen on the primary monitor while the player uses the in-game
//                     PC; minimized otherwise (it keeps running so the in-game screen
//                     stays live). The PC that is not current stays minimized.
//   the inventory     fullscreen on the second monitor while the game's inventory is open
// Meta+Esc leaves the in-game PC.
import QtQuick
import org.kde.kwin

Item {
    id: root
    property bool pcWasVisible: false
    property bool invWasVisible: false
    property string lastError: ""

    DBusCall {
        id: stateCall
        service: "org.totv.VotvOS"
        path: "/org/totv/VotvOS"
        dbusInterface: "org.totv.VotvOS"
        method: "WindowState"
        onFinished: (returnValue) => {
            try { root.apply(JSON.parse(returnValue[0])); }
            catch (e) {
                // Once per distinct error: this runs ten times a second.
                const msg = String(e);
                if (msg !== root.lastError) { root.lastError = msg; console.warn("votv-os-wm:", msg); }
            }
        }
    }

    DBusCall {
        id: leaveCall
        service: "org.totv.VotvOS"
        path: "/org/totv/VotvOS"
        dbusInterface: "org.totv.VotvOS"
        method: "LeavePC"
    }

    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: stateCall.call()
    }

    ShortcutHandler {
        name: "TotV OS: Leave PC"
        text: "TotV OS: leave the in-game PC"
        sequence: "Meta+Escape"
        onActivated: leaveCall.call()
    }

    function outputNamed(name) {
        const screens = Workspace.screens;
        for (let i = 0; i < screens.length; ++i) {
            if (screens[i].name === name) return screens[i];
        }
        return null;
    }

    function isGame(w, classes) {
        const rc = String(w.resourceClass || "").toLowerCase();
        const rn = String(w.resourceName || "").toLowerCase();
        for (let i = 0; i < classes.length; ++i) {
            if (rc === classes[i] || rn === classes[i]) return true;
        }
        return rc.indexOf("votv") === 0 || rn.indexOf("votv-win64") === 0;
    }

    function fill(w, output) {
        if (!output) return;
        if (w.output !== output) Workspace.sendClientToScreen(w, output);
        const area = Workspace.clientArea(KWin.FullScreenArea, output, Workspace.currentDesktop);
        w.noBorder = true;
        w.skipTaskbar = true;
        w.skipSwitcher = true;
        const g = w.frameGeometry;
        if (g.x !== area.x || g.y !== area.y || g.width !== area.width || g.height !== area.height)
            w.frameGeometry = Qt.rect(area.x, area.y, area.width, area.height);
    }

    function apply(s) {
        const primary = outputNamed(s.primary) || Workspace.activeScreen;
        const invOut = s.inventory.screen ? outputNamed(s.inventory.screen) : null;
        const invVisible = !!s.inventory.visible && invOut !== null;
        let game = null, pc = null, inv = null;
        const others = (s.pc.others || []);
        // KWin 6 QML: the window list is the property Workspace.windows (windowList() is the JS API's).
        const list = Workspace.windows;
        for (let i = 0; i < list.length; ++i) {
            const w = list[i];
            if (!w.normalWindow) continue;
            if (others.indexOf(w.pid) >= 0) {
                w.keepAbove = false;
                if (!w.minimized) w.minimized = true;
                w.skipTaskbar = true;
                continue;
            }
            if (s.pc.pid && w.pid === s.pc.pid) pc = w;
            else if (s.inventory.pid && w.pid === s.inventory.pid) inv = w;
            else if (isGame(w, s.game.classes)) game = w;
        }

        // Without the game (starting, crashed, not installed) the PC is the screen: the login
        // screen or the desktop, fullscreen, so TotV stays usable.
        const pcVisible = !!s.pc.visible || !game;

        if (game) {
            if (game.output !== primary) Workspace.sendClientToScreen(game, primary);
            if (!game.fullScreen) game.fullScreen = true;
        }

        if (pc) {
            fill(pc, primary);
            if (pcVisible) {
                if (pc.minimized) pc.minimized = false;
                pc.keepAbove = !!game;   // over the game; without it, dialogs stay on top
                if (!root.pcWasVisible) Workspace.activeWindow = pc;
            } else {
                pc.keepAbove = false;
                if (!pc.minimized) pc.minimized = true;
                if (root.pcWasVisible && game) Workspace.activeWindow = game;
            }
        }
        root.pcWasVisible = pcVisible;

        if (inv) {
            if (invVisible) {
                fill(inv, invOut);
                if (inv.minimized) inv.minimized = false;
                inv.keepAbove = true;
            } else {
                inv.keepAbove = false;
                if (!inv.minimized) inv.minimized = true;
                if (root.invWasVisible && game && !pcVisible) Workspace.activeWindow = game;
            }
        }
        root.invWasVisible = invVisible;
    }
}
