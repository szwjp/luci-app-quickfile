// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';

return view.extend({
	render: function () {
		return E('div', { class: 'iframe-container', style: 'width:100%;max-width:1600px;height:calc(100vh - 180px);min-height:800px;overflow:hidden;border-radius:10px' }, [
			E('iframe', {
				src: '/cgi-bin/luci/quickfile',
				style: 'width:100%;height:100%;border:none;border-radius:10px'
			})
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
