'use strict';
'require view';

/*
 * The file manager is a single page application that the backend serves
 * under /cgi-bin/luci/quickfile. It has to run inside this frame: the
 * backend sends no CORS headers and its terminal is a WebSocket bound to
 * the origin of the page, so frame, API and socket must share an origin.
 *
 * The frame is sized from the space that is left below the LuCI header
 * instead of a fixed offset, because that offset differs between themes
 * and the visible viewport on a phone is shorter than the layout viewport.
 */

function fitFrame(box) {
	if (!document.body.contains(box)) {
		window.removeEventListener('resize', fitFrame);
		if (window.visualViewport)
			window.visualViewport.removeEventListener('resize', fitFrame);
		return;
	}

	var offset = box.getBoundingClientRect().top + window.scrollY;
	var vh = (window.visualViewport && window.visualViewport.height) || window.innerHeight;

	box.style.height = Math.max(320, Math.round(vh - offset - 12)) + 'px';
}

return view.extend({
	render: function () {
		var loading = E('div', {
			'class': 'quickfile-loading',
			'style': `
				position: absolute;
				inset: 0;
				display: flex;
				align-items: center;
				justify-content: center;
				color: #999;
			`
		}, [ _('Loading the file manager…') ]);

		var frame = E('iframe', {
			'class': 'quickfile-frame',
			'src': '/cgi-bin/luci/quickfile',
			'title': _('Quick File Manager'),
			'frameborder': '0',
			'allowfullscreen': 'true',
			'style': `
				display: block;
				width: 100%;
				height: 100%;
				border: none;
			`
		});

		frame.addEventListener('load', function () {
			loading.remove();
		});

		var box = E('div', {
			'class': 'quickfile-container',
			'style': `
				position: relative;
				width: 100%;
				max-width: 1600px;
				margin: 0 auto;
				border-radius: 10px;
				overflow: hidden;
				overscroll-behavior: contain;
			`
		}, [ loading, frame ]);

		// The view is inserted into the page after render() returns, so the
		// measurement has to wait for the next task.
		setTimeout(function () { fitFrame(box); }, 0);
		window.addEventListener('resize', fitFrame);
		if (window.visualViewport)
			window.visualViewport.addEventListener('resize', fitFrame);

		return box;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
