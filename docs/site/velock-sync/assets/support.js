(() => {
  'use strict';
  const translations = {
    zh: {
      title: 'Velock Sync 技术支持', headerLabel: '网站页眉', homeLabel: 'Velock Sync 技术支持首页', logoAlt: 'Velock Sync 应用图标', navLabel: '页面导航', skip: '跳到主要内容', brandSupport: '技术支持', navFaq: '常见问题', navContact: '联系我们', languageLabel: '选择语言', officialSupport: '官方支持中心',
      heroTitle: '把数据放进你自己的云端', heroLead: 'Velock Sync 把格间的加密备份和你的文件，同步到你自己选择的 NAS、WebDAV 或个人网盘。这里有使用说明、常见问题和联系方式。',
      emailSupport: '邮件联系支持', browseFaq: '浏览常见问题', responseNote: '请在邮件中附上设备型号、系统版本、Sync 版本和问题描述，我们会尽快回复。',
      privacyFirst: '你的云端', localProtection: '不经过我们的服务器', startHere: '从这里开始', quickTitle: '快速找到你需要的帮助',
      accountTitle: '连接云端', accountDesc: 'WebDAV、NAS 与个人网盘', dataTitle: '文件同步', dataDesc: '同步位置、方向与冲突', securityTitle: '格间备份', securityDesc: '加密备份、恢复与授权',
      faqEyebrow: '使用帮助', faqTitle: '常见问题', faqLead: '以下答案可以帮助你快速解决大多数问题。',
      q1: '支持哪些云端存储？', a1: '支持任何 WebDAV 服务（群晖、威联通、飞牛等 NAS，Nextcloud、坚果云等），以及用你自己的开发者应用密钥登录的 Google Drive、OneDrive、百度网盘和阿里云盘。在「设置 › 云端账号与保存位置」里添加连接；局域网里只有 HTTP 的 NAS 也可以使用，App 会先请你确认风险。',
      q2: '文件同步是怎么工作的？会删除我的文件吗？', a2: '每个同步位置把本机一个文件夹和云端一个文件夹绑定，可选择双向、仅上传或仅下载。第一次同步只合并、不删除任何文件。之后一边删除的文件会同步到另一边；一次删除数量超过安全阈值时，App 会列出具体文件请你确认。两边同时改了同一个文件时，默认两份都保留。',
      q3: '格间备份安全吗？Sync 能看到我的数据吗？', a3: '格间的内容在交给 Sync 之前已经在设备上由格间加密，Sync 只负责传输加密后的对象，看不到其中的账号、密码、文件或照片。注意：「文件同步」与格间备份不同，云端保存的是普通明文文件。',
      q4: '换了新手机，怎么恢复格间备份？', a4: '在新手机上安装格间和 Sync。在 Sync 的格间页选择「从云端恢复」，连接原来的云端位置并取回加密恢复文件，再在格间中用纸质恢复卡恢复原账号，回到 Sync 按提示继续即可。Sync 不会向你索取恢复卡上的密码。',
      q5: '为什么连接失败或提示没有写入权限？', a5: '请检查服务器地址、端口、用户名和密码；很多 NAS 的共享入口或聚合视图是只读的，需要进入一个这个账号确实能写入的文件夹。服务器在局域网时，请在 iPhone「设置 › 隐私与安全性 › 本地网络」中允许 Velock Sync。',
      q6: '反馈问题时应提供哪些信息？', a6: '请提供 Sync 版本、设备型号、系统版本、复现步骤和错误截图。也可以在「设置 › 导出脱敏诊断」导出诊断文本附在邮件中，其中不含服务器地址、账号和文件内容。请勿发送密码、恢复卡或令牌。',
      stillNeedHelp: '仍然需要帮助？', contactTitle: '把遇到的问题告诉我们', contactLead: '发送邮件至 service@windata.tech。请尽量详细描述问题，但不要发送任何密码或敏感数据。',
      includeTitle: '建议在邮件中包含', include1: '设备型号与系统版本', include2: 'Velock Sync 版本（及格间版本）', include3: '问题复现步骤与截图', footerTagline: '你的数据，存在你的云端', privacyPolicy: '隐私政策', supportEmail: '支持邮箱'
    },
    en: {
      title: 'Velock Sync Support', headerLabel: 'Site header', homeLabel: 'Velock Sync support home', logoAlt: 'Velock Sync app icon', navLabel: 'Page navigation', skip: 'Skip to main content', brandSupport: 'Support', navFaq: 'FAQ', navContact: 'Contact', languageLabel: 'Choose language', officialSupport: 'Official support center',
      heroTitle: 'Your data, in your own cloud', heroLead: 'Velock Sync moves Velock\'s encrypted backups and your files to the NAS, WebDAV server or personal cloud drive you choose. Find guides, answers and contact details here.',
      emailSupport: 'Email support', browseFaq: 'Browse the FAQ', responseNote: 'Please include your device model, system version, Sync version and a description of the issue. We will reply as soon as possible.',
      privacyFirst: 'Your cloud', localProtection: 'Never through our servers', startHere: 'Start here', quickTitle: 'Find the help you need',
      accountTitle: 'Connect storage', accountDesc: 'WebDAV, NAS and cloud drives', dataTitle: 'File sync', dataDesc: 'Locations, directions, conflicts', securityTitle: 'Velock backup', securityDesc: 'Encrypted backup and restore',
      faqEyebrow: 'Help', faqTitle: 'Frequently asked questions', faqLead: 'These answers solve most common issues.',
      q1: 'Which cloud storage is supported?', a1: 'Any WebDAV service (Synology, QNAP and other NAS devices, Nextcloud and more), plus Google Drive, OneDrive, Baidu Netdisk and Aliyun Drive signed in with your own developer app keys. Add connections under Settings › Cloud accounts and locations. A local NAS that only offers HTTP also works after you confirm the risk.',
      q2: 'How does file sync work? Will it delete my files?', a2: 'Each sync location pairs one folder on the device with one folder in the cloud: two-way, upload only or download only. The first sync only merges and never deletes. Later, a file deleted on one side is deleted on the other; if a run would delete more than the safety threshold, the app lists the exact files and asks you first. When both sides changed the same file, both copies are kept by default.',
      q3: 'Is the Velock backup safe? Can Sync see my data?', a3: 'Velock encrypts its content on your device before handing it to Sync. Sync only transfers the encrypted objects and cannot see the accounts, passwords, files or photos inside. Note that file sync is different: the cloud copy is made of ordinary, unencrypted files.',
      q4: 'How do I restore a Velock backup on a new phone?', a4: 'Install Velock and Velock Sync on the new phone. In Sync\'s Velock tab choose Restore from the cloud, connect to the original location to fetch the encrypted recovery file, restore your account in Velock with the paper recovery card, then return to Sync and follow the prompts. Sync never asks for the password on your recovery card.',
      q5: 'Why does a connection fail or say the folder is not writable?', a5: 'Check the server address, port, user name and password. Many NAS share roots and aggregated views are read-only, so open a folder this account can actually write to. For a server on your local network, allow Velock Sync under iPhone Settings › Privacy & Security › Local Network.',
      q6: 'What should I include when reporting an issue?', a6: 'Include the Sync version, device model, system version, steps to reproduce and screenshots. You can also attach the text from Settings › Export sanitized diagnostics, which contains no server addresses, accounts or file contents. Never send passwords, recovery cards or tokens.',
      stillNeedHelp: 'Still need help?', contactTitle: 'Tell us what happened', contactLead: 'Email service@windata.tech with as much detail as possible. Do not include passwords or sensitive data.',
      includeTitle: 'Helpful details to include', include1: 'Device model and system version', include2: 'Velock Sync version (and Velock version)', include3: 'Steps to reproduce and screenshots', footerTagline: 'Your data, in your cloud', privacyPolicy: 'Privacy Policy', supportEmail: 'Support Email'
    }
  };

  const picker = document.getElementById('language');
  const privacyLink = document.getElementById('privacy-link');

  function applyLanguage(language) {
    const lang = translations[language] ? language : 'zh';
    const dictionary = translations[lang];
    document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
    document.title = dictionary.title;
    document.querySelectorAll('[data-i18n]').forEach((element) => {
      const value = dictionary[element.dataset.i18n];
      if (value) element.textContent = value;
    });
    document.querySelectorAll('[data-i18n-aria]').forEach((element) => {
      const value = dictionary[element.dataset.i18nAria];
      if (value) element.setAttribute('aria-label', value);
    });
    document.querySelectorAll('[data-i18n-alt]').forEach((element) => {
      const value = dictionary[element.dataset.i18nAlt];
      if (value) element.setAttribute('alt', value);
    });
    picker.value = lang;
    privacyLink.href = `${lang}/privacy_policy.html`;
    try { localStorage.setItem('velock-sync-support-language', lang); } catch (_) {}
  }

  let savedLanguage = '';
  try { savedLanguage = localStorage.getItem('velock-sync-support-language') || ''; } catch (_) {}
  applyLanguage(savedLanguage || 'en');
  picker.addEventListener('change', (event) => applyLanguage(event.target.value));
  document.getElementById('year').textContent = new Date().getFullYear();
})();
