import Foundation

/// Transport-level acknowledgement for a successfully accepted external task.
/// This is deliberately separate from the task result: acceptance is spoken
/// immediately, while completion follows the durable report-offer workflow.
public enum HermesDelegationAcknowledgement {
    public static func phrase(languageTag: String?) -> String {
        let language = (languageTag ?? "").lowercased().split(separator: "-").first.map(String.init) ?? ""
        return switch language {
        case "ko": "컴퓨터 관리자에게 맡겼어요. 끝나면 알려드릴게요."
        case "zh": "我已经交给电脑管理员处理了，完成后会告诉你。"
        case "ja": "コンピュータ管理エージェントに任せました。終わったらお知らせします。"
        case "es": "Se lo encargué al agente que administra el equipo. Te avisaré cuando termine."
        case "fr": "Je l’ai confié à l’agent qui gère l’ordinateur. Je vous préviendrai quand ce sera terminé."
        case "de": "Ich habe es an den Computer-Agenten übergeben. Ich sage Bescheid, sobald es fertig ist."
        case "pt": "Passei a tarefa para o agente que gerencia o computador. Avisarei quando terminar."
        case "it": "Ho affidato il compito all’agente che gestisce il computer. Ti avviserò quando sarà finito."
        case "ru": "Я передал задачу агенту, управляющему компьютером. Сообщу, когда она будет выполнена."
        case "ar": "سلّمت المهمة إلى وكيل إدارة الكمبيوتر، وسأخبرك عند اكتمالها."
        case "hi": "मैंने यह काम कंप्यूटर प्रबंधन एजेंट को सौंप दिया है। पूरा होने पर बता दूँगा।"
        default: "I handed it to the computer supervisor. I’ll let you know when it is finished."
        }
    }

    public static func controllerEvent(languageTag: String?) -> String {
        let language = languageTag.flatMap(PersonContextFormat.normalizedLanguageTag) ?? "und"
        return """
        ⟦SOMA_HERMES_DELEGATION_ACCEPTED language=\(language) delivery=once_then_listen⟧
        \(phrase(languageTag: languageTag))
        ⟦/SOMA_HERMES_DELEGATION_ACCEPTED⟧
        """
    }
}

public enum HermesDelegationAcknowledgementPolicy {
    public static func shouldInject(
        successfulDelegation: Bool,
        assistantSpeechObserved: Bool,
        alreadyHandled: Bool
    ) -> Bool {
        successfulDelegation && !assistantSpeechObserved && !alreadyHandled
    }
}
