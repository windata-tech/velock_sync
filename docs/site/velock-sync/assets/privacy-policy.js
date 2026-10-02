/* Velock Sync privacy policy — static renderer. No analytics or remote assets. */
(function () {
  'use strict';

  const mail = '<a href="mailto:service@windata.tech">service@windata.tech</a>';
  const policies = {
    zh: {
      locale: 'zh-CN', lang: '简体中文', title: '隐私政策', updated: '最后更新：2026 年 10 月 1 日',
      intro: 'WinData（“我们”）运营 Velock Sync（“Sync”）。Sync 把你设备上的数据传输到<strong>你自己选择的</strong>云端存储（例如你的 NAS、WebDAV 服务或个人网盘），并负责格间（Velock）加密备份的传输。Sync 不需要注册账户，我们没有、也不运营任何接收你数据的服务器。',
      sections: [
        ['我们不收集任何数据', '我们不收集、不接收、不出售、不出租你的任何个人信息或使用数据。Sync 不包含广告 SDK、第三方统计分析或跨应用追踪技术，也不会创建用户画像。'],
        ['你的数据去哪里', 'Sync 只与你亲自添加的云端连接通信：WebDAV 服务器，或你用自己的账号授权的 Google Drive、OneDrive、百度网盘、阿里云盘。数据直接在你的设备与该服务之间传输，不经过我们。这些服务如何处理数据由它们各自的隐私政策约束，我们无法控制。'],
        ['格间备份', '格间备份的内容在交给 Sync 之前已由格间（Velock）在你的设备上加密。Sync 只传输加密后的对象，无法读取其中的账号、密码、文件或照片。恢复时同样由格间在设备上解密。'],
        ['文件同步是明文', '「文件同步」会把你选择的本机文件夹与云端文件夹保持一致，云端保存的是普通文件，<strong>不加密</strong>。能访问该云端账号的人都可以查看和修改这些文件，App 在创建同步位置前会明确提示。'],
        ['在设备上保存的信息', 'Sync 在设备本地保存：你添加的连接（服务器地址、用户名等）、同步位置与运行记录、应用设置。密码与登录令牌保存在系统安全存储（Apple 钥匙串 / Android Keystore）中。日志不包含密码、密钥或文件内容。'],
        ['设备权限', '文件与文件夹：仅访问你在系统文件选择器中明确选择的文件夹。本地网络：当你的服务器位于局域网（如家用 NAS）时，系统会请求本地网络权限。后台刷新：仅用于继续你开启了后台同步的任务。你可以随时在系统设置中撤销这些权限。'],
        ['诊断信息', '只有你在「设置 › 导出脱敏诊断」中主动导出时，才会生成诊断文本；其中不含服务器地址、账号、密码、文件名或文件内容，由你自行决定是否发送给我们。'],
        ['保留与删除', '删除连接会同时删除对应的登录凭据；删除同步位置不会删除本机或云端的任何文件；卸载 App 会删除 Sync 保存在设备上的全部数据。你存放在云端的文件由你在相应服务中自行管理。'],
        ['儿童隐私', 'Sync 不面向 13 岁以下儿童，也不会有意收集任何人的个人信息。'],
        ['政策更新与联系方式', `如本政策有重要变更，我们会更新本页面并修改“最后更新”日期。如有任何问题，请联系 ${mail}。`]
      ]
    },
    en: {
      locale: 'en', lang: 'English', title: 'Privacy Policy', updated: 'Last updated: October 1, 2026',
      intro: 'WinData ("we") operates Velock Sync ("Sync"). Sync moves data from your device to cloud storage <strong>that you choose</strong> (for example your NAS, a WebDAV service or your personal cloud drive), and carries the encrypted backups of Velock. Sync has no sign-up, and we do not run any server that receives your data.',
      sections: [
        ['We collect no data', 'We do not collect, receive, sell or rent any personal information or usage data. Sync contains no advertising SDK, no third-party analytics and no cross-app tracking, and builds no user profiles.'],
        ['Where your data goes', 'Sync only talks to connections you add yourself: a WebDAV server, or Google Drive, OneDrive, Baidu Netdisk or Aliyun Drive authorized with your own account. Data travels directly between your device and that service, never through us. How those services handle data is governed by their own privacy policies, which we do not control.'],
        ['Velock backup', 'Velock backup data is encrypted on your device by the Velock app before it is handed to Sync. Sync only transfers encrypted objects and cannot read the accounts, passwords, files or photos inside them. Restoring is decrypted by Velock on your device as well.'],
        ['File sync is plaintext', 'File sync keeps a folder on your device and a folder in your cloud storage in step. The cloud copy consists of ordinary files and is <strong>not encrypted</strong>: anyone with access to that cloud account can read and change them. The app says so before a sync location is created.'],
        ['Information kept on your device', 'Sync stores on your device: the connections you add (server address, user name and similar), sync locations and run history, and app settings. Passwords and sign-in tokens are kept in the system secure storage (Apple Keychain / Android Keystore). Logs never contain passwords, keys or file contents.'],
        ['Device permissions', 'Files and folders: only folders you explicitly pick in the system document picker are accessed. Local network: requested when your server is on your local network (such as a home NAS). Background refresh: only used to continue tasks you switched background sync on for. You can revoke these permissions in system settings at any time.'],
        ['Diagnostics', 'A diagnostics text is only created when you export it yourself from Settings › Export sanitized diagnostics. It contains no server addresses, accounts, passwords, file names or file contents, and you decide whether to send it to us.'],
        ['Retention and deletion', 'Deleting a connection deletes its stored credentials. Deleting a sync location deletes no files on the device or in the cloud. Uninstalling the app removes everything Sync stored on the device. Files in your cloud storage are managed by you through that service.'],
        ['Children', 'Sync is not directed at children under 13 and does not knowingly collect personal information from anyone.'],
        ['Changes and contact', `If this policy changes materially, we will update this page and its "Last updated" date. For any question, contact ${mail}.`]
      ]
    }
  };

  function render(locale) {
    const p = policies[locale] || policies.en;
    document.documentElement.lang = p.locale;
    document.title = `Velock Sync — ${p.title}`;
    const choices = Object.entries(policies).map(([key, item]) => `<option value="${key}"${key === locale ? ' selected' : ''}>${item.lang}</option>`).join('');
    document.body.innerHTML = `<main><header><div class="brand">VELOCK SYNC</div><label class="language"><span>Language</span><select aria-label="Language" onchange="location.href='../' + this.value + '/privacy_policy.html'">${choices}</select></label></header><article><p class="eyebrow">WIN DATA · VELOCK SYNC</p><h1>${p.title}</h1><p class="updated">${p.updated}</p><p class="intro">${p.intro}</p>${p.sections.map(([heading, text]) => `<section><h2>${heading}</h2><p>${text}</p></section>`).join('')}</article><footer>© 2026 WinData · Velock Sync · <a href="../support.html">${locale === 'zh' ? '技术支持' : 'Support'}</a></footer></main>`;
  }
  window.VelockSyncPrivacyPolicy = { render };
}());
