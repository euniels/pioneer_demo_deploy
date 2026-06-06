// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import '../theme/app_theme.dart';

Future<bool> exportSoaHtmlAsPdf(String title, String htmlContent) async {
  final frame = html.IFrameElement()
    ..style.position = 'fixed'
    ..style.right = '0'
    ..style.bottom = '0'
    ..style.width = '0'
    ..style.height = '0'
    ..style.border = '0'
    ..srcdoc =
        '''
      <!doctype html>
      <html>
      <head>
        <title>$title</title>
        <style>
        body { font-family: Arial, sans-serif; padding: 24px; color: ${AppTheme.css18212F}; }
        h1 { margin: 0 0 8px; color: ${AppTheme.css1A3A6B}; }
        .muted { color: ${AppTheme.css64748B}; margin-bottom: 20px; }
        table { border-collapse: collapse; width: 100%; margin-top: 16px; }
        th, td { border: 1px solid ${AppTheme.cssD8E1F0}; padding: 8px; text-align: left; }
        th { background: ${AppTheme.cssF0F6FF}; color: ${AppTheme.css1A3A6B}; }
        td.num { text-align: right; }
        .total { margin-top: 18px; font-weight: 700; }
        </style>
      </head>
      <body>$htmlContent<script>window.addEventListener('load', function(){ setTimeout(function(){ window.print(); }, 200); });</script></body>
      </html>
    ''';
  html.document.body?.append(frame);
  await frame.onLoad.first;
  final blob = html.Blob([frame.srcdoc ?? htmlContent], 'text/html');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = 'pioneerpath-soa-export.html'
    ..click();
  html.Url.revokeObjectUrl(url);
  frame.remove();
  return true;
}

Future<bool> exportSoaCsv(String filename, String csvContent) async {
  final blob = html.Blob([csvContent], 'text/csv;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = filename.endsWith('.csv') ? filename : '$filename.csv'
    ..click();
  html.Url.revokeObjectUrl(url);
  return true;
}

Future<bool> printHtmlDocument(String title, String htmlContent) async {
  final document =
      '''
      <!doctype html>
      <html>
      <head>
        <title>$title</title>
        <style>
        body { font-family: Arial, sans-serif; padding: 28px; color: ${AppTheme.css18212F}; }
        h1 { margin: 0 0 6px; color: ${AppTheme.css1A3A6B}; }
        h2 { margin: 24px 0 10px; color: ${AppTheme.css1A3A6B}; font-size: 18px; }
        .muted { color: ${AppTheme.css64748B}; margin-bottom: 20px; }
        .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px 24px; }
        .label { color: ${AppTheme.css64748B}; font-size: 11px; text-transform: uppercase; letter-spacing: .04em; }
        .value { font-weight: 700; margin-top: 2px; }
        .box { border: 1px solid ${AppTheme.cssD8E1F0}; border-radius: 10px; padding: 14px; margin-top: 12px; }
        .signature { height: 72px; border-bottom: 1px solid ${AppTheme.css18212F}; margin-top: 36px; }
        @media print { body { padding: 12mm; } .no-print { display: none; } }
        </style>
      </head>
      <body>$htmlContent</body>
      </html>
    ''';
  final blob = html.Blob([document], 'text/html;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.window.open(url, '_blank');
  Future<void>.delayed(
    const Duration(minutes: 1),
    () => html.Url.revokeObjectUrl(url),
  );
  return true;
}
