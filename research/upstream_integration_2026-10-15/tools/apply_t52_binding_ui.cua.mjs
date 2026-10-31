// Run through cua_repl for the explicitly approved independent t52-v2.
export async function run(cua, nodeRepl) {
  const fs = await import('node:fs/promises');
  const root = '/Users/kolar/github/vphone-cli';
  const output = root+'/.build/t52-real-20261021/ui';
  const backup = root+'/.build/t52-real-20261021/v2-first-binding-backup';
  const app = await cua.getApp(root+'/.build/t52-entrypoints-launchpad-20261021.app');
  const ensure = (ok, message) => { if (!ok) throw new Error(message); };
  const index = (state, pattern) => {
    const match = state.match(pattern);
    ensure(match, 'Missing UI element: '+pattern);
    return Number(match[1]);
  };
  const save = async name => {
    const value = await app.getAXStateAndScreenshot({disableDiffing:true,emit:false});
    await fs.writeFile(output+'/'+name+'.ax.txt',value.state);
    if (value.screenshot) await fs.writeFile(output+'/'+name+'.png',value.screenshot);
    return value.state;
  };
  ensure(!(await fs.stat(backup).catch(()=>null)), 'Backup must be a new directory');
  let state = await save('positive-binding-default');
  ensure(state.includes('文本 Core Bundle 绑定') && state.includes('Value: t52-v2'), 'Wrong binding target');
  ensure(state.includes('Value: 2.6.2-local.cd529f26a150'), 'Wrong verified Bundle');
  ensure(/转换 绑定后更新客户机环境, Value: off/.test(state), 'Update must default off');
  ensure(/按钮 \(disabled\) 应用/.test(state), 'First binding must require backup');
  await app.setValue(index(state,/^\s*(\d+) 文本栏 \(settable\) 新备份目录$/m),backup);
  state = await app.getAXState({disableDiffing:true,emit:false});
  await app.click(index(state,/^\s*(\d+) 转换 绑定后更新客户机环境, Value: off$/m));
  state = await save('positive-binding-prepared');
  ensure(state.includes(backup) && /Value: on/.test(state), 'Backup and update selection missing');
  ensure(state.includes('管理员认证') && state.includes('工作父目录（可选）'), 'Update requirements missing');
  await app.click(index(state,/^\s*(\d+) 按钮 应用$/m));
  state = await save('positive-binding-started');
  await fs.writeFile(output+'/positive-binding-submission.json',JSON.stringify({
    submittedAt:new Date().toISOString(),machine:'t52-v2',bundle:'2.6.2-local.cd529f26a150',
    backup,updatesEnvironment:true,completionVerified:false},null,2)+'\n');
  nodeRepl.write(state);
}
