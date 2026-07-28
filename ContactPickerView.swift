import SwiftUI
import ContactsUI

/// Presenta el selector nativo de contactos del sistema para elegir un teléfono.
/// Usa un UIViewController relay que lanza CNContactPickerViewController en viewDidAppear,
/// evitando problemas de jerarquía con sheets de SwiftUI.
/// No requiere el permiso NSContactsUsageDescription.
struct ContactPickerView: UIViewControllerRepresentable {
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> RelayVC {
        let relay = RelayVC()
        relay.view.backgroundColor = .clear
        relay.onReady = { [weak relay] in
            guard let relay else { return }
            let picker = CNContactPickerViewController()
            picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
            picker.delegate = context.coordinator
            relay.present(picker, animated: false)
        }
        return relay
    }

    func updateUIViewController(_ uiViewController: RelayVC, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Relay VC

    class RelayVC: UIViewController {
        var onReady: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onReady?()
            onReady = nil
        }
    }

    // MARK: - Delegado CNContactPicker

    class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPickerView

        init(parent: ContactPickerView) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController,
                           didSelect property: CNContactProperty) {
            guard let phone = property.value as? CNPhoneNumber else { return }
            parent.onSelect(phone.stringValue)
            parent.onDismiss()
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onDismiss()
        }
    }
}
