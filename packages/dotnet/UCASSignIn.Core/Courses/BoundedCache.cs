namespace UCASSignIn.Core;

// Immutable parse results only. FIFO eviction keeps memory bounded across account lifetimes.
internal sealed class BoundedCache<TKey, TValue>(int capacity) where TKey : notnull
{
    readonly object gate = new();
    readonly Dictionary<TKey, TValue> values = [];
    readonly Queue<TKey> order = [];
    public TValue Get(TKey key, Func<TKey, TValue> create)
    {
        lock (gate) if (values.TryGetValue(key, out var value)) return value;
        var result = create(key);
        lock (gate)
        {
            if (values.TryGetValue(key, out var value)) return value;
            if (values.Count >= capacity) values.Remove(order.Dequeue());
            values[key] = result; order.Enqueue(key); return result;
        }
    }
}
