// Run in cua_repl after selecting com.vphone.bundle; counts come from the same old guest's RPC snapshot.
// This script only opens, refreshes and filters lists. It never invokes list mutation actions.
function mixedGUIHarness(app, expected) {
    const results = [];
    const state = () => app.getAXState({emit:false, disableDiffing:true});
    const index = (text, pattern) => {
        const line = text.split('\n').find(line => pattern.test(line));
        if (!line) throw Error('Missing UI target: '+pattern);
        return Number(line.match(/^\s*(\d+) /)[1]);
    };
    const click = async pattern => { const text=await state(); await app.click(index(text,pattern)); return state(); };
    const open = async (menu, item) => { await click(menu); return click(item); };
    const refresh = () => click(/按钮 Description: (刷新|Refresh),/);
    const close = async () => { await app.pressKey('super+w'); await state(); };
    const check = (condition, name, details={}) => { if(!condition)throw Error(name);results.push({name,passed:true,...details}); };
    const search = async (placeholder, text) => { const s=await state();await app.setValue(index(s,placeholder),text);return state(); };
    return {
        results,
        async filesAppsProcesses() {
            await open(/^\s*\d+ (数据|Data)$/, /ID: openFiles$/);
            const files=await refresh();check(files.includes('文本 '+expected.files+' 项'),'legacy file refresh',{count:expected.files});await close();
            await open(/^\s*\d+ App$/, /ID: openAppBrowser$/);
            const apps=await refresh();check(apps.includes('文本 '+expected.apps+' 个 App'),'legacy apps refresh',{count:expected.apps});await close();
            await open(/^\s*\d+ (诊断|Diagnostics)$/, /\d+ (进程|Processes), ID: openPanel:$/);
            await refresh();const processes=await search(/搜索文本栏[^\n]*(搜索进程|Search Processes)/,'vphoned');
            check(processes.includes('/usr/bin/vphoned'),'legacy processes refresh and search');await close();
            return results;
        },
        async servicesCrashes() {
            await open(/^\s*\d+ (诊断|Diagnostics)$/, /\d+ (服务|Services), ID: openPanel:$/);
            const all=await refresh();check(all.includes(expected.services+' / '+expected.services+' 个服务'),'legacy services refresh',{count:expected.services});
            const services=await search(/搜索文本栏[^\n]*(标签或程序|Label or program)/,'com.vphone.vphoned');
            check(services.includes('com.vphone.vphoned'),'legacy service search');await close();
            await open(/^\s*\d+ (诊断|Diagnostics)$/, /\d+ (崩溃日志|Crash Logs), ID: openPanel:$/);
            const crashes=await refresh();check(crashes.includes('外框 崩溃报告')&&crashes.includes('row (selectable)'),'legacy crash list refresh');await close();
            return results;
        },
    };
}
