// Run only through cua_repl, after action-time authorization for this candidate.
// This regression never applies a binding or starts a VM.
export async function run(cua, nodeRepl, {appPath, outputDirectory}) {
  const fs = await import('node:fs/promises');
  await fs.mkdir(outputDirectory, {recursive:true});
  const app = await cua.getApp(appPath);
  const ensure = (condition, message) => { if (!condition) throw new Error(message); };
  const index = (state, pattern) => {
    const match = state.match(pattern);
    ensure(match, 'Missing UI element: '+pattern);
    return Number(match[1]);
  };
  const save = async name => {
    const observation = await app.getAXStateAndScreenshot({disableDiffing:true,emit:false});
    await fs.writeFile(outputDirectory+'/'+name+'.ax.txt',observation.state);
    if (observation.screenshot) await fs.writeFile(outputDirectory+'/'+name+'.png',observation.screenshot);
    return observation.state;
  };
  let state = await app.getAXState({disableDiffing:true,emit:false});
  if (state.includes('文本 Core Bundle 绑定')) {
    await app.click(index(state,/^\s*(\d+) 按钮 取消$/m));
    state = await app.getAXState({disableDiffing:true,emit:false});
  }
  ensure(state.includes('e347a55812c8') && state.includes('7bddc387f858'),'Candidate identity differs');
  await app.click(index(state,/^\s*(\d+) row \([^\n]*\) target$/m));
  state = await save('selected');
  ensure(state.includes('Help: 已停止'),'Expected stopped acceptance machine');
  const openSheet = async () => {
    let current = await app.getAXState({disableDiffing:true,emit:false});
    // A menu can disappear between observations. Re-observe before
    // retrying; never retain indices from a dismissed menu.
    for (let attempt=0; attempt<3; attempt++) {
      await app.click(index(current,/^\s*(\d+) 菜单按钮 更多, ID: ellipsis$/m));
      current = await app.getAXState({disableDiffing:true,emit:false});
      await fs.writeFile(outputDirectory+'/menu-'+attempt+'.ax.txt',current);
      const item=current.match(/^\s*(\d+) 更改 Core Bundle…, ID: menuAction:$/m);
      if (item) {
        await app.click(Number(item[1]));
        return await app.getAXState({disableDiffing:true,emit:false});
      }
    }
    throw new Error('Binding menu unavailable after three observations');
  };
  await openSheet();
  state = await save('default');
  ensure(state.includes('没有记录 Core Bundle 绑定'),'Missing legacy binding notice');
  ensure(state.includes('未安装已验证且兼容的 Core Bundle'),'Missing verified Bundle refusal');
  ensure(state.includes('首次绑定要求在虚拟机目录外建立经过完整校验的备份'),'Missing complete backup requirement');
  ensure(/转换 绑定后更新客户机环境, Value: off/.test(state),'Environment replacement must default off');
  ensure(/按钮 \(disabled\) 应用/.test(state),'Apply must be disabled');
  await app.click(index(state,/^\s*(\d+) 转换 绑定后更新客户机环境, Value: off$/m));
  state = await save('environment-enabled');
  ensure(state.includes('工作父目录（可选）'),'Work parent field missing');
  ensure(state.includes('管理员认证'),'Authentication requirement missing');
  ensure(state.includes('环境更新失败或取消时，新宿主绑定会保留'),'Binding retention notice missing');
  ensure(/按钮 \(disabled\) 应用/.test(state),'Missing Bundle must still block Apply');
  await app.setValue(index(state,/^\s*(\d+) 文本栏 \(settable\) 新备份目录.*$/m),outputDirectory+'/not-created-backup');
  state = await save('backup-entered');
  ensure(/按钮 \(disabled\) 应用/.test(state),'A backup path cannot bypass the verified Bundle requirement');
  await app.click(index(state,/^\s*(\d+) 按钮 取消$/m));
  state = await save('cancelled');
  ensure(!state.includes('文本 Core Bundle 绑定') && state.includes('Help: 已停止'),'Cancel must return to stopped machine');
  ensure(!(await fs.stat(outputDirectory+'/not-created-backup').catch(()=>null)),'Cancel created a backup directory');
  await openSheet();
  state = await save('reopened');
  ensure(/转换 绑定后更新客户机环境, Value: off/.test(state),'Reopened update choice must default off');
  ensure(!state.includes('not-created-backup'),'Cancelled backup path persisted');
  await app.click(index(state,/^\s*(\d+) 按钮 取消$/m));
  state = await save('final');
  ensure(state.includes('Help: 已停止') && state.includes('launchpad.json is missing'),'Machine state or binding changed');
  const result={state:'passed',recordedAt:new Date().toISOString(),appPath,
    assertions:['exact candidate identity','stopped target','first complete backup required','only verified compatible Bundle selectable',
      'environment update defaults off','work parent and authentication notice','Apply disabled without Bundle even with backup path',
      'cancel returns without backup creation','reopen resets options','binding remains absent'],
    appliedBinding:false,vmStarted:false,amfiChanged:false};
  await fs.writeFile(outputDirectory+'/result.json',JSON.stringify(result,null,2)+'\n');
  nodeRepl.write(result);
}
