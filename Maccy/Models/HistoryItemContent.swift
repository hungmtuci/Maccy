import Foundation
import Observation
import SwiftData

nonisolated final class HistoryItemContent: PersistentModel, Observable, @unchecked Sendable {
  private let _$observationRegistrar = Observation.ObservationRegistrar()
  var _$backingData: any SwiftData.BackingData<HistoryItemContent> = HistoryItemContent.createBackingData()

  var persistentBackingData: any SwiftData.BackingData<HistoryItemContent> {
    get { _$backingData }
    set { _$backingData = newValue }
  }

  static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
    return [
      SwiftData.Schema.PropertyMetadata(
        name: "type",
        keypath: \HistoryItemContent.type,
        defaultValue: "",
        metadata: nil
      ),
      SwiftData.Schema.PropertyMetadata(
        name: "value",
        keypath: \HistoryItemContent.value,
        defaultValue: nil,
        metadata: nil
      ),
      SwiftData.Schema.PropertyMetadata(
        name: "item",
        keypath: \HistoryItemContent.item,
        defaultValue: nil,
        metadata: nil
      )
    ]
  }

  var type: String {
    get {
      _$observationRegistrar.access(self, keyPath: \.type)
      return self.getValue(forKey: \.type)
    }
    set {
      _$observationRegistrar.withMutation(of: self, keyPath: \.type) {
        self.setValue(forKey: \.type, to: newValue)
      }
    }
  }

  var value: Data? {
    get {
      _$observationRegistrar.access(self, keyPath: \.value)
      return self.getValue(forKey: \.value)
    }
    set {
      _$observationRegistrar.withMutation(of: self, keyPath: \.value) {
        self.setValue(forKey: \.value, to: newValue)
      }
    }
  }

  var item: HistoryItem? {
    get {
      _$observationRegistrar.access(self, keyPath: \.item)
      return self.getValue(forKey: \.item)
    }
    set {
      _$observationRegistrar.withMutation(of: self, keyPath: \.item) {
        self.setValue(forKey: \.item, to: newValue)
      }
    }
  }

  init(type: String, value: Data? = nil) {
    _$backingData.setValue(forKey: \.type, to: type)
    _$backingData.setValue(forKey: \.value, to: value)
    _$backingData.setValue(forKey: \.item, to: nil)
  }

  required init(backingData: any SwiftData.BackingData<HistoryItemContent>) {
    self._$backingData = backingData
  }
}
