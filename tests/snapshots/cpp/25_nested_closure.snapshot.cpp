
namespace {

BallDyn compose(std::function<int64_t(int64_t)> f, std::function<int64_t(int64_t)> g);

BallDyn compose(std::function<int64_t(int64_t)> f, std::function<int64_t(int64_t)> g) {
    return [&, f, g](BallDyn x) mutable {
        return f(g(x));
    };
    return BallDyn();
}

} // namespace

int main() {
    auto inc = BallDyn([&](BallDyn x) mutable {
        return (x + static_cast<int64_t>(1));
    });
    auto dbl = BallDyn([&](BallDyn x) mutable {
        return (x * static_cast<int64_t>(2));
    });
    auto incThenDouble = BallDyn(compose(dbl, inc));
    auto doubleThenInc = BallDyn(compose(inc, dbl));
    std::cout << ball_to_string(ball_to_string(incThenDouble(static_cast<int64_t>(3)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(doubleThenInc(static_cast<int64_t>(3)))) << std::endl;
    return 0;
}
