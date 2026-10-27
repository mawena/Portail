import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/ai/ai_servers_screen.dart';
import 'package:fluluks/src/ai/chat_list_screen.dart';
import 'package:fluluks/src/ai/chat_screen.dart';
import 'package:fluluks/src/app.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/ui/root.dart';

import 'fake_ai_api.dart';
import 'fake_host_api.dart';

/// Phase 15, T7 : écran de chat (liste des conversations, conversation, réponses en flux).
void main() {
  /// Laisse passer une seconde par pas de 100 ms : l'indicateur d'une réponse en cours tourne sans fin, ce que
  /// `pumpAndSettle` ne supporte pas.
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<AppState> pumpPage(WidgetTester t, FakeHostApi api, Widget Function(AppState)? page) async {
    final state = AppState(api);
    await state.loadUiPrefs();
    await state.refresh();
    await t.pumpWidget(const SizedBox.shrink()); // arbre neuf : rien ne reste d'un écran précédent
    await t.pumpWidget(PortailRoot(state: state, builder: (_) => FluLuksApp(state: state)));
    await settle(t);
    if (page != null) {
      t.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => page(state)));
      await settle(t);
    }
    return state;
  }

  FakeHostApi withServer() => FakeHostApi()
    ..aiServerList.addAll([
      aiServer('a1', 'Atelier', 'https://atelier.mawena.cloud', isDefault: true, model: 'essai-court'),
      aiServer('a2', 'PC du salon', 'http://192.168.0.20:11434', hasKey: false),
    ]);

  /// Une conversation terminée : « Bonjour » puis la réponse [reply].
  Future<FakeHostApi> withConversation({String reply = 'Salut, que puis-je faire ?'}) async {
    final api = withServer();
    await api.createConversation('a1', 'essai-court');
    await api.sendChatMessage(1, 'Bonjour');
    api.finishFakeReply(1, reply);
    api.aiCalls.clear();
    return api;
  }

  /// Texte visible de tous les RichText, bout à bout.
  String allText(WidgetTester t) =>
      t.widgetList<RichText>(find.byType(RichText)).map((r) => r.text.toPlainText()).join('\n');

  String? Function() captureClipboard(WidgetTester t) {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    return () => copied;
  }

  Future<void> send(WidgetTester t, String text) async {
    await t.enterText(find.byType(TextField), text);
    await t.pump();
    await t.tap(find.byTooltip(Fr.chatSend));
    await settle(t);
  }

  int replyId(FakeHostApi api, int conv) => api.chatMessages[conv]!.last.id;

  testWidgets('homeOpensChatList', (t) async {
    await pumpPage(t, withServer(), null);
    await t.scrollUntilVisible(find.text(Fr.chatTitle), 300, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text(Fr.chatTitle));
    await settle(t);
    expect(find.byType(ChatListScreen), findsOneWidget);
  });

  testWidgets('noServerLeadsToAiServers', (t) async {
    await pumpPage(t, FakeHostApi(), (s) => ChatListScreen(state: s));
    expect(find.text(Fr.aiNoServers), findsOneWidget);
    expect(find.text(Fr.chatNoServersBody), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, Fr.aiServers));
    await settle(t);
    expect(find.byType(AiServersScreen), findsOneWidget);
  });

  testWidgets('newConversationSendsAndStreams', (t) async {
    final api = withServer();
    final state = await pumpPage(t, api, (s) => ChatListScreen(state: s));
    expect(find.text(Fr.chatNoConversations), findsOneWidget);
    await t.tap(find.text(Fr.chatNew).first);
    await settle(t);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.text('Atelier · essai-court'), findsOneWidget);
    expect(api.aiCalls.where((c) => c.startsWith('createConversation')), isEmpty, reason: 'créée au premier envoi');

    await send(t, 'Bonjour');
    expect(api.aiCalls, containsAllInOrder(['createConversation a1 essai-court', 'sendChatMessage 1 Bonjour']));
    final bubble = find.descendant(of: find.byKey(const ValueKey('chat-messages')), matching: find.text('Bonjour'));
    expect(bubble, findsOneWidget); // bulle de l'utilisateur
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Bonjour')), findsOneWidget); // titre auto
    expect(find.byTooltip(Fr.chatStop), findsOneWidget);
    expect(find.byTooltip(Fr.chatSend), findsNothing);

    state.chats.onChatDelta(1, replyId(api, 1), 'Salut ');
    state.chats.onChatDelta(1, replyId(api, 1), '**toi**');
    await t.pump();
    expect(allText(t), contains('Salut toi'));

    state.chats.onChatState(api.finishFakeReply(1, 'Salut **toi**'));
    await settle(t);
    expect(find.byTooltip(Fr.chatStop), findsNothing);
    expect(find.byTooltip(Fr.chatRegenerate), findsOneWidget);
    expect(find.byTooltip(Fr.chatCopyReply), findsOneWidget);
    expect(allText(t), contains('Salut toi'));
  });

  testWidgets('stopKeepsPartialAnswer', (t) async {
    final api = withServer();
    final state = await pumpPage(t, api, (s) => ChatScreen(state: s));
    await send(t, 'Raconte');
    state.chats.onChatDelta(1, replyId(api, 1), 'Il était une fois');
    await t.pump();
    await t.tap(find.byTooltip(Fr.chatStop));
    await t.pump();
    expect(api.aiCalls, contains('stopGeneration 1'));
    state.chats.onChatState(api.finishFakeReply(1, 'Il était une fois', state: 'stopped'));
    await settle(t);
    expect(allText(t), contains('Il était une fois'));
    expect(find.text(Fr.chatStopped), findsOneWidget);
    expect(find.byTooltip(Fr.chatSend), findsOneWidget);
  });

  testWidgets('regenerateAndCopyLastAnswer', (t) async {
    final api = await withConversation(reply: 'Réponse **un**');
    final copied = captureClipboard(t);
    await pumpPage(t, api, (s) => ChatScreen(state: s, conversationId: 1));
    await t.tap(find.byTooltip(Fr.chatCopyReply));
    await t.pump();
    expect(copied(), 'Réponse **un**');
    await settle(t);
    await t.tap(find.byTooltip(Fr.chatRegenerate));
    await settle(t);
    expect(api.aiCalls, contains('regenerate 1'));
    expect(find.byTooltip(Fr.chatStop), findsOneWidget);
  });

  testWidgets('failedAnswerShowsReasonAndRetry', (t) async {
    final api = withServer();
    final state = await pumpPage(t, api, (s) => ChatScreen(state: s));
    await send(t, 'Bonjour');
    state.chats.onChatState(api.finishFakeReply(1, '',
        state: 'failed', error: 'Le serveur ne répond plus. Réessayez plus tard.', errorDetail: 'upstream timeout'));
    await settle(t);
    expect(find.text('Le serveur ne répond plus. Réessayez plus tard.'), findsOneWidget);
    expect(find.text('upstream timeout'), findsOneWidget);
    await t.tap(find.text(Fr.retry));
    await settle(t);
    expect(api.aiCalls, contains('regenerate 1'));
  });

  testWidgets('interruptedAnswerIsLabelled', (t) async {
    final api = withServer();
    await api.createConversation('a1', 'essai-court');
    await api.sendChatMessage(1, 'Bonjour');
    api.finishFakeReply(1, 'Début', state: 'interrupted');
    await pumpPage(t, api, (s) => ChatScreen(state: s, conversationId: 1));
    expect(find.text(Fr.chatInterrupted), findsOneWidget);
    expect(find.text(Fr.retry), findsOneWidget);
  });

  testWidgets('reopenedWhileStreamingShowsTextReceivedMeanwhile', (t) async {
    final api = withServer();
    final state = await pumpPage(t, api, (s) => ChatScreen(state: s));
    await send(t, 'Bonjour');
    t.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(t);
    state.chats.onChatDelta(1, replyId(api, 1), 'Texte reçu écran fermé');
    t.state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => ChatScreen(state: state, conversationId: 1)));
    await settle(t);
    expect(allText(t), contains('Texte reçu écran fermé'));
    expect(find.byTooltip(Fr.chatStop), findsOneWidget);
  });

  testWidgets('followsAnswerUntilUserScrollsUp', (t) async {
    final api = withServer();
    final state = await pumpPage(t, api, (s) => ChatScreen(state: s));
    await send(t, 'Longue réponse');
    final id = replyId(api, 1);
    final list = find.byKey(const ValueKey('chat-messages'));
    ScrollPosition pos() =>
        t.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable)).first).position;
    for (var i = 0; i < 40; i++) {
      state.chats.onChatDelta(1, id, 'Ligne $i\n\n');
      await settle(t);
    }
    expect(pos().maxScrollExtent, greaterThan(0));
    expect(pos().pixels, pos().maxScrollExtent, reason: 'suit la réponse');

    await t.drag(list, const Offset(0, 300));
    await settle(t);
    final kept = pos().pixels;
    for (var i = 40; i < 50; i++) {
      state.chats.onChatDelta(1, id, 'Ligne $i\n\n');
      await settle(t);
    }
    expect(pos().pixels, kept, reason: "l'utilisateur lit plus haut : on ne le déplace pas");
    expect(pos().pixels, lessThan(pos().maxScrollExtent));
  });

  testWidgets('slowDragUpDuringAnswerIsNotUndone', (t) async {
    final api = withServer();
    final state = await pumpPage(t, api, (s) => ChatScreen(state: s));
    await send(t, 'Longue réponse');
    final id = replyId(api, 1);
    final list = find.byKey(const ValueKey('chat-messages'));
    ScrollPosition pos() =>
        t.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable)).first).position;
    for (var i = 0; i < 40; i++) {
      state.chats.onChatDelta(1, id, 'Ligne $i\n\n');
      await settle(t);
    }
    expect(pos().pixels, pos().maxScrollExtent);

    // le doigt remonte lentement pendant que la réponse continue d'arriver
    final g = await t.startGesture(t.getCenter(list));
    for (var i = 40; i < 60; i++) {
      await g.moveBy(const Offset(0, 10));
      state.chats.onChatDelta(1, id, 'Ligne $i\n\n');
      await settle(t);
    }
    await g.up();
    await settle(t);
    expect(pos().maxScrollExtent - pos().pixels, greaterThan(100), reason: "le geste de l'utilisateur n'est pas annulé");
  });

  testWidgets('renameAndDeleteFromListLongPress', (t) async {
    final api = await withConversation();
    await pumpPage(t, api, (s) => ChatListScreen(state: s));
    expect(find.text('Bonjour'), findsOneWidget); // titre automatique
    await t.longPress(find.text('Bonjour'));
    await settle(t);
    await t.tap(find.text(Fr.rename));
    await settle(t);
    await t.enterText(find.byType(TextField), 'Courses');
    await t.tap(find.text(Fr.ok));
    await settle(t);
    expect(api.aiCalls, contains('renameConversation 1 Courses'));
    expect(find.text('Courses'), findsOneWidget);

    await t.longPress(find.text('Courses'));
    await settle(t);
    await t.tap(find.text(Fr.delete));
    await settle(t);
    expect(find.text(Fr.chatDeleteTitle), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, Fr.delete));
    await settle(t);
    expect(api.aiCalls, contains('deleteConversation 1'));
    expect(find.text('Courses'), findsNothing);
  });

  testWidgets('renameAndDeleteFromConversation', (t) async {
    final api = await withConversation();
    await pumpPage(t, api, (s) => ChatScreen(state: s, conversationId: 1));
    await t.tap(find.byTooltip(Fr.moreOptions));
    await settle(t);
    await t.tap(find.text(Fr.rename));
    await settle(t);
    await t.enterText(find.byType(TextField).last, 'Voyage');
    await t.tap(find.text(Fr.ok));
    await settle(t);
    expect(api.aiCalls, contains('renameConversation 1 Voyage'));
    expect(find.text('Voyage'), findsOneWidget); // titre de la barre

    await t.tap(find.byTooltip(Fr.moreOptions));
    await settle(t);
    await t.tap(find.text(Fr.delete));
    await settle(t);
    await t.tap(find.widgetWithText(FilledButton, Fr.delete));
    await settle(t);
    expect(api.aiCalls, contains('deleteConversation 1'));
    expect(find.byType(ChatScreen), findsNothing);
  });

  testWidgets('systemPromptFromMenu', (t) async {
    final api = await withConversation();
    await pumpPage(t, api, (s) => ChatScreen(state: s, conversationId: 1));
    await t.tap(find.byTooltip(Fr.moreOptions));
    await settle(t);
    await t.tap(find.text(Fr.chatSystemPrompt));
    await settle(t);
    await t.enterText(find.byType(TextField).last, 'Réponds en une phrase.');
    await t.tap(find.text(Fr.save));
    await settle(t);
    expect(api.aiCalls, contains('setSystemPrompt 1 Réponds en une phrase.'));
  });

  testWidgets('serverAndModelChosenFromTitle', (t) async {
    final api = await withConversation();
    await pumpPage(t, api, (s) => ChatScreen(state: s, conversationId: 1));
    await t.tap(find.text('Atelier · essai-court'));
    await settle(t);
    expect(find.text(Fr.chatChooseModel), findsOneWidget);
    await t.tap(find.text('essai-long').first);
    await settle(t);
    expect(api.aiCalls, contains('setConversationModel 1 a1 essai-long'));
    expect(find.text('Atelier · essai-long'), findsOneWidget);
  });

  testWidgets('linkInAnswerOpensAfterConfirmation', (t) async {
    final api = await withConversation(reply: 'Voir [la doc](https://exemple.fr/doc).');
    await pumpPage(t, api, (s) => ChatScreen(state: s, conversationId: 1));
    await t.tapOnText(find.textRange.ofSubstring('la doc'));
    await settle(t);
    await t.tap(find.text(Fr.chatOpenLink));
    await settle(t);
    expect(api.openedUrls, ['https://exemple.fr/doc']);
  });

  testWidgets('sendErrorShownAndTextKept', (t) async {
    final api = await withConversation();
    // FL_EBUSY côté Kotlin : trois réponses déjà en cours dans d'autres conversations
    api.chatSendError = PlatformException(code: '-16', message: 'Trois réponses sont déjà en cours');
    await pumpPage(t, api, (s) => ChatScreen(state: s, conversationId: 1));
    await send(t, 'Encore');
    expect(find.text('Trois réponses sont déjà en cours'), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, 'Encore');
  });

  testWidgets('hiddenFromCapturesOnlyWhenSettingOn', (t) async {
    final off = await withConversation();
    await pumpPage(t, off, (s) => ChatScreen(state: s, conversationId: 1));
    expect(off.secureScreen, isNull, reason: 'réglage désactivé par défaut');

    final on = await withConversation()
      ..uiPrefs = UiPrefsMsg(theme: 'system', haptics: true, welcomeSeen: true, hideChats: true);
    await pumpPage(t, on, (s) => ChatListScreen(state: s));
    expect(on.secureScreen, isTrue);
    await t.tap(find.text('Bonjour'));
    await settle(t);
    expect(on.secureScreen, isTrue);
    t.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(t);
    expect(on.secureScreen, isTrue, reason: 'la liste reste affichée');
    t.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(t);
    expect(on.secureScreen, isFalse);
  });

  testWidgets('wideScreenShowsListAndConversationSideBySide', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final api = await withConversation(reply: 'Première réponse');
    await api.createConversation('a1', 'essai-court');
    await api.sendChatMessage(2, 'Deuxième question');
    api.finishFakeReply(2, 'Deuxième réponse');
    await pumpPage(t, api, (s) => ChatListScreen(state: s));
    expect(find.byType(ChatScreen), findsOneWidget, reason: 'conversation à côté de la liste');
    expect(allText(t), contains('Deuxième réponse')); // la plus récente, ouverte d'office
    await t.tap(find.text('Bonjour'));
    await settle(t);
    expect(allText(t), contains('Première réponse'));
    expect(find.text('Bonjour'), findsWidgets);
  });
}
