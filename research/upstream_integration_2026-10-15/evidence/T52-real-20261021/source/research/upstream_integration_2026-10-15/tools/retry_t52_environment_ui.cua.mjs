// Run after action-time authorization for the environment inheritance repair.
export async function run(cua, nodeRepl) {
  const fs = await import('node:fs/promises');
  const root = '/Users/kolar/github/vphone-cli';
  const app = await cua.getApp(root+'/.build/t52-envfix-launchpad-20261022.app');
  const output = root+'/.build/t52-real-20261021/ui';
  const ensure = (ok, message) => { if (!ok) throw new Error(message); };
  const index = (state, pattern) => {
    const match = state.match(pattern);
    ensure(match, 'Missing UI element: '+pattern);
    return Number(match[1]);
  };
  const save = async name => {
    const observation = await app.getAXStateAndScreenshot({disableDiffing:true,emit:false});
    await fs.writeFile(output+'/'+name+'.ax.txt',observation.state);
    if (observation.screenshot) await fs.writeFile(output+'/'+name+'.png',observation.screenshot);
    return observation.state;
  };
  let state = await app.getAXState({disableDiffing:true,emit:false});
  if (!state.includes('文本 Core Bundle 绑定')) {
    await app.click(index(state,/^\s*(\d+) row \([^\n]*\) t52-v2$/m));
    state = await save('environment-retry-selected');
    ensure(state.includes('Help: 已停止') && state.includes('Help: 2.6.2-local.cd529f26a150'), 'Bound VM must be stopped');
    for (let attempt=0; attempt<3; attempt++) {
      await app.click(index(state,/^\s*(\d+) 菜单按钮 更多, ID: ellipsis$/m));
      state = await app.getAXState({disableDiffing:true,emit:false});
      const action = state.match(/^\s*(\d+) 更改 Core Bundle…, ID: menuAction:$/m);
      if (action) { await app.click(Number(action[1])); break; }
    }
  }
  state = await app.getAXState({disableDiffing:true,emit:false});
  for (let attempt=0; attempt<3 && (state.includes('新备份目录') || !state.includes('弹出式按钮 核心 Bundle')); attempt++) {
    state = await app.getAXState({disableDiffing:true,emit:false});
  }
  state = await save('environment-retry-default');
  ensure(state.includes('文本 Core Bundle 绑定') && state.includes('Value: t52-v2'), 'Wrong target');
  ensure(state.includes('Value: 2.6.2-local.cd529f26a150') && !state.includes('新备份目录'), 'Existing verified binding not loaded');
  await app.click(index(state,/^\s*(\d+) 转换 绑定后更新客户机环境, Value: off$/m));
  state = await save('environment-retry-prepared');
  await app.click(index(state,/^\s*(\d+) 按钮 应用$/m));
  state = await save('environment-retry-started');
  await fs.writeFile(output+'/environment-retry-submission.json',JSON.stringify({
    submittedAt:new Date().toISOString(),machine:'t52-v2',bundle:'2.6.2-local.cd529f26a150',
    existingBackupPreserved:true,updatesEnvironment:true,completionVerified:false},null,2)+'\n');
  nodeRepl.write(state);
}
