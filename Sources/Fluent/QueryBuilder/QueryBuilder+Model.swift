extension QueryBuilder where Result: Model, Result.Database == Database {
    // MARK: Model
    
    /// Saves the supplied model. Calls `create(...)` if the ID is `nil`, and `update(...)` if it exists.
    /// If you need to create a model with a pre-existing ID, call `create(...)` instead.
    ///
    ///     let user = User(...)
    ///     User.query(on: conn).save(user)
    ///
    /// - parameters:
    ///     - model: `Model` to save.
    /// - returns: A `Future` containing the saved `Model`.
    public func save(_ model: Result) -> Future<Result> {
        if model.fluentID != nil {
            return update(model)
        } else {
            return create(model)
        }
    }
    
    /// Saves this model as a new item in the database.
    /// This method can auto-generate an ID depending on ID type.
    ///
    ///     let user = User(...)
    ///     User.query(on: conn).create(user)
    ///
    /// - parameters:
    ///     - model: `Model` to create.
    /// - returns: A `Future` containing the created `Model`.
    public func create(_ model: Result) -> Future<Result> {
        return create([model]).map { created in
            guard let first = created.first else {
                throw FluentError(identifier: "noModelCreated", reason: "Expected a model to be returned after it is created, but none where found.")
            }
            return first
        }
    }
    
    
    /// Saves an array of models as new items in the database.
    /// This method can auto-generate the IDs depending on the ID type.
    ///
    ///     let users = [User(...), User(...), User(...)]
    ///     User.query(on: conn).create(users)
    ///
    /// - parameters:
    ///   - models: `Model` objects to create.
    /// - returns: A `Future` containg the created `Model` objects.
    func create(_ models: [Result]) -> Future<[Result]> {
        Database.queryActionApply(Database.queryActionCreate, to: &query)
        var copy: [Result] = []
        copy.reserveCapacity(models.count)
        
        if Result.createdAtKey != nil || Result.updatedAtKey != nil {
            let now = Date()
            
            for var model in models {
                if Result.createdAtKey != nil, model.fluentCreatedAt == nil {
                    model.fluentCreatedAt = now
                }
                
                if Result.updatedAtKey != nil, model.fluentUpdatedAt == nil {
                    model.fluentUpdatedAt = now
                }
                copy.append(model)
            }
        } else {
            copy = models
        }
        
        return connection.flatMap { conn in
            let willCreate: [Future<Result>] = copy.map { model -> Future<Result> in
                return Database.modelEvent(event: .willCreate, model: model, on: conn).flatMap { model in
                    return try model.willCreate(on: conn)
                }
            }
            let create: Future<[Result]> = willCreate.flatten(on: conn).flatMap { models -> Future<[Result]> in
                var copy = models
                var modelCreated = 0
                try models.forEach { model in
                    try Database.queryDataApply(Database.queryEncode(model, entity: Result.entity), to: &self.query)
                }
                return self.run(Database.queryActionCreate) { created in
                    guard modelCreated < copy.count else { return }
                    
                    copy[modelCreated].fluentID = created.fluentID
                    copy[modelCreated] = created
                    
                    modelCreated += 1
                    }.transform(to: copy)
            }
            let didCreate: Future<[Result]> = create.flatMap { models in
                return models.map { model in
                    return Database.modelEvent(event: .didCreate, model: model, on: conn)
                    }.flatten(on: conn)
                }.flatMap { models in
                    return try models.map { model -> Future<Result> in
                        return try model.didCreate(on: conn)
                        }.flatten(on: conn)
            }
            return didCreate
        }
    }
    
    /// Updates the model. This requires that the model has its ID set.
    ///
    ///     let user: User = ...
    ///     User.query(on: conn).update(user, originalID: 42)
    ///
    /// - parameters:
    ///     - model: `Model` to update.
    ///     - originalID: Specify the original ID if the ID has changed.
    /// - returns: A `Future` containing the created `Model`.
    public func update(_ model: Result, originalID: Result.ID? = nil) -> Future<Result> {
        Database.queryActionApply(Database.queryActionUpdate, to: &query)
        var copy: Result
        if Result.updatedAtKey != nil {
            // set timestamps
            copy = model
            copy.fluentUpdatedAt = Date()
        } else {
            copy = model
        }
        
        return connection.flatMap { conn -> Future<Result> in
            guard let id = originalID ?? model.fluentID else {
                throw FluentError(identifier: "idRequired", reason: "No ID was set on updated model, it is required for updating.")
            }
            
            // update record w/ matching id
            self.filter(Result.idKey == id)
            return Database.modelEvent(event: .willUpdate, model: copy, on: conn).flatMap { model in
                return try copy.willUpdate(on: conn)
                }.flatMap { model in
                    return self.update(data: model).transform(to: model)
                }.flatMap { model -> Future<Result> in
                    return Database.modelEvent(event: .didUpdate, model: model, on: conn)
                }.flatMap { model in
                    return try model.didUpdate(on: conn)
            }
        }
    }
    
    /// Deletes the supplied model. Throws an error if the mdoel did not have an id.
    ///
    ///     let user: User = ...
    ///     User.query(on: conn).delete(user)
    ///
    /// - parameters:
    ///     - model: `Model` to delete.
    ///     - force: If `true`, the model will be deleted from the database even if it has a `deletedAtKey`.
    ///              This is `false` by default.
    /// - returns: A `Future` containing the created `Model`.
    internal func delete(_ model: Result, force: Bool) -> Future<Void> {
        if !force, let _ = Result.deletedAtKey {
            return connection.flatMap { conn in
                return try model.willSoftDelete(on: conn).flatMap { model -> Future<Result> in
                    var copy = model
                    copy.fluentDeletedAt = Date()
                    return self.update(copy)
                    }.flatMap { model in
                        return try model.didSoftDelete(on: conn)
                }
                }.transform(to: ())
        } else {
            return connection.flatMap { conn in
                guard let id = model.fluentID else {
                    throw FluentError(identifier: "idRequired", reason: "No ID was set on updated model, it is required for updating.")
                }
                // update record w/ matching id
                self.filter(Result.idKey == id)
                return Database.modelEvent(event: .willDelete, model: model,on: conn).flatMap { model in
                    return try model.willDelete(on: conn)
                    }.flatMap { model in
                        return self.run(Database.queryActionDelete).transform(to: model)
                    }.flatMap { model in
                        return try model.didDelete(on: conn)
                    }.transform(to: ())
            }
        }
    }
    
    /// Restores a soft deleted model.
    ///
    ///     let user: User = ...
    ///     User.query(on: conn).restore(user)
    ///
    /// - parameters:
    ///     - model: `Model` to restore.
    /// - returns: A future that will return the succesfully restored model.
    internal func restore(_ model: Result) -> Future<Result> {
        return connection.flatMap { conn in
            return try model.willRestore(on: conn).flatMap { model -> Future<Result> in
                var copy = model
                copy.fluentDeletedAt = nil
                return self.update(copy)
                }.flatMap { model in
                    return try model.didRestore(on: conn)
            }
        }
    }
}
